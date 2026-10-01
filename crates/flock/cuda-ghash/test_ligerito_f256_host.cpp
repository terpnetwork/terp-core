// Host-only (no GPU/nvcc) replay of the F256 Ligerito ladder against the real
// Rust driver's dump ("LF25", from dump_ligerito_f256_vectors.rs). Validates
// the ENTIRE ladder orchestration locally — transcript order, F256 fold/
// code-switch algebra, recursive commits + caps, level OODs, stratified query
// phases + capped paths, transpose-NTT induce, presplit introduce/glue, and
// all three PoW nonce families — before anything costs a Blackwell CI run.
// The CUDA twin (test_ligerito_f256.cu) then checks the device kernels
// against the same oracle.
//
// Build:  make test_ligerito_f256_host
// Run:    (repo root)  cargo run --release --bin dump_ligerito_f256_vectors -- \
//                        cuda-ghash/ligerito_f256_vectors.bin 22
//         (cuda-ghash) ./test_ligerito_f256_host ligerito_f256_vectors.bin
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <map>
#include <algorithm>

typedef unsigned long long u64;
struct F128 { u64 lo, hi; };
#include "ntt_host.hpp"     // f128 host math + twiddle tables
#include "f256.cuh"         // F256Ext (host paths)
#include "challenger.hpp"   // FsChallenger + stratified helpers (host)
#include "merkle_open.hpp"  // MHash + merkle_capped_path_indices (host)

static F128 fadd(F128 a, F128 b) { return f128_add_hd(a, b); }
static F128 fmul(F128 a, F128 b) { return f128_mul_hd(a, b); }
static bool eq128(F128 a, F128 b) { return a.lo == b.lo && a.hi == b.hi; }
static ChF128 toch(F128 x) { return ChF128{x.lo, x.hi}; }
static F128 frch(ChF128 x) { return F128{x.lo, x.hi}; }
static F256Ext fr256(ChF256 x) { return F256Ext{frch(x.c0), frch(x.c1)}; }

static uint32_t rd_u32(FILE* f) { uint32_t v; if (fread(&v, 4, 1, f) != 1) { printf("short u32\n"); exit(1); } return v; }
static uint64_t rd_u64(FILE* f) { uint64_t v; if (fread(&v, 8, 1, f) != 1) { printf("short u64\n"); exit(1); } return v; }
static F128 rd_f128(FILE* f) { F128 v; if (fread(&v, 16, 1, f) != 1) { printf("short f128\n"); exit(1); } return v; }
static MHash rd_hash(FILE* f) { MHash h; if (fread(h.b, 1, 32, f) != 32) { printf("short hash\n"); exit(1); } return h; }

// ---- host merkle (SHA-256: leaf = H(bytes), node = H(l || r)) --------------
static std::vector<MHash> merkle_tree_host(const std::vector<F128>& cw, size_t num_leaves,
                                           size_t lanes) {
    std::vector<MHash> tree(2 * num_leaves - 1);
    for (size_t i = 0; i < num_leaves; i++) {
        Sha256 h;
        h.update((const uint8_t*)&cw[i * lanes], lanes * 16);
        h.finalize(tree[i].b);
    }
    size_t read = 0, len = num_leaves;
    while (len > 1) {
        for (size_t i = 0; i < len / 2; i++) {
            Sha256 h;
            h.update(tree[read + 2 * i].b, 32);
            h.update(tree[read + 2 * i + 1].b, 32);
            h.finalize(tree[read + len + i].b);
        }
        read += len;
        len >>= 1;
    }
    return tree;
}

// ---- host interleaved forward NTT (host_check_ntt.cpp's reference) ---------
static void forward_ntt_host(std::vector<F128>& cw, const TwiddleTable& tt, int log_inv_rate,
                             int log_d, long long num_ntts) {
    for (int layer = log_inv_rate; layer < log_d; layer++) {
        long long num_blocks = 1LL << layer;
        long long block_size = 1LL << (log_d - layer);
        long long half = block_size >> 1;
        long long block_size_elts = block_size * num_ntts;
        for (long long block = 0; block < num_blocks; block++) {
            F128 tw = twiddle_from_table(tt, layer, block);
            long long block_start = block * block_size_elts;
            for (long long row = 0; row < half; row++) {
                long long off_top = block_start + row * num_ntts;
                long long off_bot = off_top + half * num_ntts;
                for (long long lane = 0; lane < num_ntts; lane++) {
                    F128 v = cw[off_bot + lane];
                    F128 u = fadd(cw[off_top + lane], fmul(v, tw));
                    cw[off_top + lane] = u;
                    cw[off_bot + lane] = fadd(v, u);
                }
            }
        }
    }
}

// ---- host transposed NTT (ntt_transpose.cuh's butterfly, layers reversed) --
static void transpose_ntt_host(std::vector<F128>& data, const TwiddleTable& tt, int log_d) {
    for (int layer = log_d - 1; layer >= 0; layer--) {
        long long bsh = 1LL << (log_d - layer - 1);
        long long half_total = 1LL << (log_d - 1);
        for (long long idx = 0; idx < half_total; idx++) {
            long long block = idx / bsh;
            long long j = idx - block * bsh;
            long long base = block * (bsh << 1);
            F128 t = twiddle_from_table(tt, layer, block);
            F128 a = data[base + j], b = data[base + j + bsh];
            F128 s = fadd(a, b);
            data[base + j] = s;
            data[base + j + bsh] = fadd(fmul(t, s), b);
        }
    }
}

static std::vector<F128> build_eq_host_vec(const std::vector<F128>& r) {
    std::vector<F128> t;
    t.reserve((size_t)1 << r.size());
    t.push_back(F128{1ull, 0ull});
    for (F128 rj : r) {
        F128 opr = fadd(F128{1ull, 0ull}, rj);
        size_t len = t.size();
        t.resize(2 * len);
        for (size_t x = 0; x < len; x++) {
            F128 v = t[x];
            t[x + len] = fmul(v, rj);
            t[x] = fmul(v, opr);
        }
    }
    return t;
}

static int ceil_log2_host(size_t n) {
    int c = 0;
    while (((size_t)1 << c) < n) c++;
    return c;
}

struct Msg256 { F256Ext u0, u2; };

int main(int argc, char** argv) {
    const char* path = argc > 1 ? argv[1] : "ligerito_f256_vectors.bin";
    FILE* f = fopen(path, "rb");
    if (!f) { printf("cannot open %s (run dump_ligerito_f256_vectors first)\n", path); return 1; }
    if (rd_u32(f) != 0x3532464Cu) { printf("bad file (want LF25)\n"); return 1; }
    uint32_t dlen = rd_u32(f);
    std::vector<uint8_t> domain(dlen);
    if (fread(domain.data(), 1, dlen, f) != dlen) { printf("short domain\n"); return 1; }
    uint32_t m = rd_u32(f);
    int log_n = (int)rd_u32(f);
    int initial_k = (int)rd_u32(f);
    int r = (int)rd_u32(f);
    auto rd_ints = [&](int n) { std::vector<int> v(n); for (auto& x : v) x = (int)rd_u32(f); return v; };
    std::vector<int> rates = rd_ints(r + 1), ks = rd_ints(r), queries = rd_ints(r + 1),
                     gbits = rd_ints(r + 1), cbits = rd_ints(r + 1), xbits = rd_ints(r + 1),
                     oods = rd_ints(r + 1);
    long long l0_bl = (long long)rd_u64(f);
    int l0_lanes = (int)rd_u32(f);
    long long len = 1LL << log_n;
    std::vector<F128> wit(len), bas(len);
    for (auto& x : wit) x = rd_f128(f);
    for (auto& x : bas) x = rd_f128(f);
    F128 target = rd_f128(f);

    // expected proof
    uint32_t n_icap = rd_u32(f);
    std::vector<MHash> e_icap(n_icap);
    for (auto& h : e_icap) h = rd_hash(f);
    uint32_t n_rcaps = rd_u32(f);
    std::vector<std::vector<MHash>> e_rcaps(n_rcaps);
    for (auto& cap : e_rcaps) { cap.resize(rd_u32(f)); for (auto& h : cap) h = rd_hash(f); }
    struct ExpOpen { uint32_t n_rows, row_len; std::vector<F128> rows; std::vector<MHash> path; };
    uint32_t n_opens = rd_u32(f);
    std::vector<ExpOpen> e_opens(n_opens);
    for (auto& o : e_opens) {
        o.n_rows = rd_u32(f);
        o.row_len = rd_u32(f);
        o.rows.resize((size_t)o.n_rows * o.row_len);
        for (auto& x : o.rows) x = rd_f128(f);
        o.path.resize(rd_u32(f));
        for (auto& h : o.path) h = rd_hash(f);
    }
    uint32_t n_yr = rd_u32(f);
    std::vector<F128> e_yr(n_yr);
    for (auto& x : e_yr) x = rd_f128(f);
    uint32_t n_tx = rd_u32(f);
    std::vector<F128> e_tx(4 * (size_t)n_tx);
    for (auto& x : e_tx) x = rd_f128(f);
    uint32_t n_ood = rd_u32(f);
    std::vector<F128> e_ood(n_ood);
    for (auto& x : e_ood) x = rd_f128(f);
    auto rd_nonces = [&]() { std::vector<uint64_t> v(rd_u32(f)); for (auto& x : v) x = rd_u64(f); return v; };
    std::vector<uint64_t> e_gn = rd_nonces(), e_cn = rd_nonces(), e_xn = rd_nonces();
    fclose(f);
    printf("LF25: m=%u log_n=%d initial_k=%d r=%d (%u tx msgs)\n", m, log_n, initial_k, r, n_tx);

    // ---- outputs being accumulated ----
    std::vector<Msg256> transcript;
    std::vector<F128> ood_values;
    std::vector<uint64_t> g_nonces, c_nonces, x_nonces;
    std::vector<std::vector<MHash>> rcaps;
    std::vector<ExpOpen> opens(n_opens);

    const int n1 = log_n - initial_k;
    // schedules
    std::vector<std::vector<uint32_t>> depths(r + 1);
    std::vector<uint32_t> capd(r + 1);
    {
        int dim = n1 + 1;
        depths[0] = stratified_depths((size_t)queries[0], (uint32_t)ceil_log2_host((size_t)l0_bl));
        capd[0] = stratified_cap_depth(depths[0]);
        for (int lvl = 1; lvl <= r; lvl++) {
            int log_cols = dim - ks[lvl - 1];
            depths[lvl] = stratified_depths((size_t)queries[lvl], (uint32_t)(log_cols + rates[lvl]));
            capd[lvl] = stratified_cap_depth(depths[lvl]);
            dim = log_cols + 1;
        }
    }

    // ---- L0 commit (replicate + forward NTT + merkle) ----
    int k_code0 = (log_n - initial_k) + rates[0];
    TwiddleTable tt0 = build_twiddle_table(k_code0);
    std::vector<F128> cw0((size_t)l0_bl * l0_lanes);
    for (size_t i = 0; i < cw0.size(); i++) cw0[i] = wit[i % (size_t)len];
    forward_ntt_host(cw0, tt0, rates[0], k_code0, l0_lanes);
    std::vector<MHash> tree0 = merkle_tree_host(cw0, (size_t)l0_bl, (size_t)l0_lanes);
    std::vector<MHash> icap((size_t)1 << capd[0]);
    for (size_t i = 0; i < icap.size(); i++)
        icap[i] = tree0[2 * (size_t)l0_bl - 2 * icap.size() + i];
    if (icap.size() != e_icap.size()) { printf("initial cap size\n"); return 1; }
    for (size_t i = 0; i < icap.size(); i++)
        if (!mhash_eq(icap[i], e_icap[i])) { printf("initial cap[%zu] differs (host L0 commit)\n", i); return 1; }
    printf("  L0 commit + cap: OK (%zu nodes)\n", icap.size());

    // ---- the ladder, serially ----
    FsChallenger ch(domain.data(), dlen);
    static const uint8_t LABEL[] = "flock-ligerito-basis-f256-split-v0";
    ch.observe_label(LABEL, sizeof(LABEL) - 1);
    ch.observe_f128(toch(target));
    ch.observe_bytes((const uint8_t*)icap.data(), icap.size() * 32);

    // round-0 message over (wit, bas) + the L0 OOD loop's β-batches.
    F128 fu0{0, 0}, fu2{0, 0};
    for (long long j = 0; j < len / 2; j++) {
        fu0 = fadd(fu0, fmul(wit[2 * j], bas[2 * j]));
        fu2 = fadd(fu2, fmul(fadd(wit[2 * j], wit[2 * j + 1]), fadd(bas[2 * j], bas[2 * j + 1])));
    }
    for (int o = 0; o < oods[0]; o++) {
        std::vector<ChF128> zc(log_n);
        ch.sample_f128_vec(zc.data(), log_n);
        std::vector<F128> z(log_n);
        for (int i = 0; i < log_n; i++) z[i] = frch(zc[i]);
        std::vector<F128> eq = build_eq_host_vec(z);
        F128 ou0{0, 0}, ou2{0, 0}, y{0, 0};
        for (long long j = 0; j < len / 2; j++) {
            ou0 = fadd(ou0, fmul(wit[2 * j], eq[2 * j]));
            ou2 = fadd(ou2, fmul(fadd(wit[2 * j], wit[2 * j + 1]), fadd(eq[2 * j], eq[2 * j + 1])));
            y = fadd(y, fadd(fmul(wit[2 * j], eq[2 * j]), fmul(wit[2 * j + 1], eq[2 * j + 1])));
        }
        ch.observe_f128(toch(y));
        ood_values.push_back(y);
        ChF128 bc;
        c_nonces.push_back(ch.grind_pow_and_sample_f128((uint32_t)cbits[0], &bc));
        F128 beta = frch(bc);
        fu0 = fadd(fu0, fmul(beta, ou0));
        fu2 = fadd(fu2, fmul(beta, ou2));
        for (long long i = 0; i < len; i++) bas[i] = fadd(bas[i], fmul(beta, eq[i]));
    }
    auto observe_msg = [&](Msg256 msg) {
        ChF128 w[2];
        w[0] = toch(msg.u0.c0); w[1] = toch(msg.u0.c1);
        ch.observe_f128_slice(w, 2);
        w[0] = toch(msg.u2.c0); w[1] = toch(msg.u2.c1);
        ch.observe_f128_slice(w, 2);
        transcript.push_back(msg);
    };
    observe_msg(Msg256{f256x_from_base(fu0), f256x_from_base(fu2)});

    // fold state
    std::vector<F256Ext> F, B;         // extension state
    std::vector<F128> Fs;              // split table (post code switch)
    std::vector<F256Ext> Bs;           // split basis
    auto msg_ext = [&](const std::vector<F256Ext>& A, const std::vector<F256Ext>& C) {
        F256Ext u0 = f256x_zero(), u2 = f256x_zero();
        for (size_t j = 0; j < A.size() / 2; j++) {
            u0 = f256x_add(u0, f256x_mul_hd(A[2 * j], C[2 * j]));
            u2 = f256x_add(u2, f256x_mul_hd(f256x_add(A[2 * j], A[2 * j + 1]),
                                            f256x_add(C[2 * j], C[2 * j + 1])));
        }
        return Msg256{u0, u2};
    };
    auto do_switch = [&]() {
        Fs.resize(2 * F.size());
        memcpy(Fs.data(), F.data(), F.size() * sizeof(F256Ext));   // (c0,c1) interleave
        Bs.resize(2 * B.size());
        for (size_t j = 0; j < B.size(); j++) {
            Bs[2 * j] = B[j];
            Bs[2 * j + 1] = f256x_mul_by_u(B[j]);
        }
        F256Ext u0 = f256x_zero(), u2 = f256x_zero();
        for (size_t j = 0; j < B.size(); j++) {
            u0 = f256x_add(u0, f256x_mul_base_hd(Bs[2 * j], Fs[2 * j]));
            u2 = f256x_add(u2, f256x_mul_base_hd(f256x_add(Bs[2 * j], Bs[2 * j + 1]),
                                                 fadd(Fs[2 * j], Fs[2 * j + 1])));
        }
        return Msg256{u0, u2};
    };

    for (int j = 0; j < initial_k; j++) {
        F256Ext rr = fr256(ch.sample_f256());
        if (j == 0) {
            F.resize(len / 2);
            B.resize(len / 2);
            for (long long i = 0; i < len / 2; i++) {
                F128 xa = fadd(wit[2 * i], wit[2 * i + 1]);
                F128 xb = fadd(bas[2 * i], bas[2 * i + 1]);
                F[i] = F256Ext{fadd(wit[2 * i], fmul(rr.c0, xa)), fmul(rr.c1, xa)};
                B[i] = F256Ext{fadd(bas[2 * i], fmul(rr.c0, xb)), fmul(rr.c1, xb)};
            }
        } else {
            size_t half = F.size() / 2;
            std::vector<F256Ext> nf(half), nb(half);
            for (size_t i = 0; i < half; i++) {
                nf[i] = f256x_add(F[2 * i], f256x_mul_hd(rr, f256x_add(F[2 * i], F[2 * i + 1])));
                nb[i] = f256x_add(B[2 * i], f256x_mul_hd(rr, f256x_add(B[2 * i], B[2 * i + 1])));
            }
            F.swap(nf);
            B.swap(nb);
        }
        observe_msg(j + 1 == initial_k ? do_switch() : msg_ext(F, B));
    }
    int split_dim = n1 + 1;

    // previous committed level (codeword + tree)
    std::vector<F128> prev_cw = std::move(cw0);
    std::vector<MHash> prev_tree = std::move(tree0);
    long long prev_bl = l0_bl;
    int prev_lanes = l0_lanes;

    // Commit the current split table for `level`, absorb its cap. Does NOT
    // touch `prev` — the caller switches prev only AFTER the level's query
    // phase has opened the OLD tree (mirrors the CUDA driver).
    struct Committed { std::vector<F128> cw; std::vector<MHash> tree; long long bl; int lanes; };
    auto commit_level = [&](int level) -> Committed {
        int log_lanes = ks[level - 1];
        int log_cols = split_dim - log_lanes;
        int rate = rates[level];
        int k_code = log_cols + rate;
        int lanes = 1 << log_lanes;
        long long bl = 1LL << k_code;
        std::vector<F128> cw((size_t)bl * lanes);
        for (size_t i = 0; i < cw.size(); i++) cw[i] = Fs[i % Fs.size()];
        TwiddleTable tt = build_twiddle_table(k_code);
        forward_ntt_host(cw, tt, rate, k_code, lanes);
        std::vector<MHash> tree = merkle_tree_host(cw, (size_t)bl, (size_t)lanes);
        std::vector<MHash> cap((size_t)1 << capd[level]);
        for (size_t i = 0; i < cap.size(); i++)
            cap[i] = tree[2 * (size_t)bl - 2 * cap.size() + i];
        ch.observe_bytes((const uint8_t*)cap.data(), cap.size() * 32);
        rcaps.push_back(cap);
        return Committed{std::move(cw), std::move(tree), bl, lanes};
    };

    auto level_oods = [&](int level) {
        for (int o = 0; o < oods[level]; o++) {
            std::vector<ChF128> zc(split_dim);
            ch.sample_f128_vec(zc.data(), split_dim);
            std::vector<F128> z(split_dim);
            for (int i = 0; i < split_dim; i++) z[i] = frch(zc[i]);
            std::vector<F128> eq = build_eq_host_vec(z);
            F128 u0{0, 0}, u2{0, 0}, y{0, 0};
            for (size_t j = 0; j < Fs.size() / 2; j++) {
                u0 = fadd(u0, fmul(Fs[2 * j], eq[2 * j]));
                u2 = fadd(u2, fmul(fadd(Fs[2 * j], Fs[2 * j + 1]), fadd(eq[2 * j], eq[2 * j + 1])));
                y = fadd(y, fadd(fmul(Fs[2 * j], eq[2 * j]), fmul(Fs[2 * j + 1], eq[2 * j + 1])));
            }
            ch.observe_f128(toch(y));
            ood_values.push_back(y);
            observe_msg(Msg256{f256x_from_base(u0), f256x_from_base(u2)});
            ChF128 bc;
            c_nonces.push_back(ch.grind_pow_and_sample_f128((uint32_t)cbits[level], &bc));
            F128 beta = frch(bc);
            for (size_t i = 0; i < Bs.size(); i++)
                Bs[i].c0 = fadd(Bs[i].c0, fmul(beta, eq[i]));
        }
    };

    // Query phase against prev; fills opens[slot] and returns (queries, alpha).
    // Each level grinds its OWN consistency bits (matches ligerito_f256.cuh
    // and the Rust driver).
    auto query_phase = [&](int open_level, ExpOpen& open,
                           std::vector<size_t>& q_out, std::vector<F128>& alpha_out) {
        q_out.clear();
        g_nonces.push_back(grind_and_sample_stratified_queries(
            ch, (uint32_t)gbits[open_level], (uint32_t)ceil_log2_host((size_t)prev_bl),
            (size_t)queries[open_level], depths[open_level], q_out));
        int al = ceil_log2_host((size_t)queries[open_level]);
        std::vector<ChF128> ac(al);
        x_nonces.push_back(
            ch.grind_pow_and_sample_f128_vec((uint32_t)xbits[open_level], ac.data(), al));
        alpha_out.resize(al);
        for (int i = 0; i < al; i++) alpha_out[i] = frch(ac[i]);
        open.n_rows = (uint32_t)q_out.size();
        open.row_len = (uint32_t)prev_lanes;
        open.rows.resize(q_out.size() * prev_lanes);
        for (size_t i = 0; i < q_out.size(); i++)
            memcpy(&open.rows[i * prev_lanes], &prev_cw[q_out[i] * prev_lanes],
                   (size_t)prev_lanes * 16);
        std::vector<size_t> idxs =
            merkle_capped_path_indices((size_t)prev_bl, q_out, capd[open_level]);
        open.path.resize(idxs.size());
        for (size_t i = 0; i < idxs.size(); i++) open.path[i] = prev_tree[idxs[i]];
    };

    auto induce_introduce_glue = [&](int ext_dim, int next_level,
                                     const std::vector<size_t>& qs,
                                     const std::vector<F128>& alpha) {
        std::vector<F128> wts = build_eq_host_vec(alpha);
        std::vector<F128> scat((size_t)prev_bl, F128{0, 0});
        for (size_t i = 0; i < qs.size(); i++) scat[qs[i]] = fadd(scat[qs[i]], wts[i]);
        TwiddleTable tt = build_twiddle_table(ceil_log2_host((size_t)prev_bl));
        transpose_ntt_host(scat, tt, ceil_log2_host((size_t)prev_bl));
        // presplit introduce over (Fs, basis of 2^ext_dim)
        long long pairs = 1LL << ext_dim;
        F128 m0{0, 0}, m2{0, 0};
        for (long long j = 0; j < pairs; j++) {
            m0 = fadd(m0, fmul(Fs[2 * j], scat[j]));
            m2 = fadd(m2, fmul(fadd(Fs[2 * j], Fs[2 * j + 1]), scat[j]));
        }
        observe_msg(Msg256{f256x_from_base(m0), F256Ext{m2, m2}});
        ChF128 bc;
        c_nonces.push_back(ch.grind_pow_and_sample_f128((uint32_t)cbits[next_level], &bc));
        F128 beta = frch(bc);
        for (long long j = 0; j < pairs; j++) {
            F128 w = fmul(beta, scat[j]);
            Bs[2 * j].c0 = fadd(Bs[2 * j].c0, w);
            Bs[2 * j + 1].c1 = fadd(Bs[2 * j + 1].c1, w);
        }
    };

    // pre-loop: commit level 1 (prev stays L0), its OODs, then open L0,
    // induce, and only then switch prev to tree 1.
    std::vector<F128> yr;
    {
        Committed next = commit_level(1);
        level_oods(1);
        std::vector<size_t> qs;
        std::vector<F128> alpha;
        query_phase(0, opens[0], qs, alpha);
        induce_introduce_glue(n1, 1, qs, alpha);
        prev_cw = std::move(next.cw);
        prev_tree = std::move(next.tree);
        prev_bl = next.bl;
        prev_lanes = next.lanes;
    }

    // recursive levels
    for (int i = 0; i < r; i++) {
        int k = ks[i];
        for (int j = 0; j < k; j++) {
            F256Ext rr = fr256(ch.sample_f256());
            if (j == 0) {
                size_t half = Fs.size() / 2;
                F.resize(half);
                B.resize(half);
                for (size_t t = 0; t < half; t++) {
                    F128 xa = fadd(Fs[2 * t], Fs[2 * t + 1]);
                    F[t] = F256Ext{fadd(Fs[2 * t], fmul(rr.c0, xa)), fmul(rr.c1, xa)};
                    B[t] = f256x_add(Bs[2 * t],
                                     f256x_mul_hd(rr, f256x_add(Bs[2 * t], Bs[2 * t + 1])));
                }
            } else {
                size_t half = F.size() / 2;
                std::vector<F256Ext> nf(half), nb(half);
                for (size_t t = 0; t < half; t++) {
                    nf[t] = f256x_add(F[2 * t], f256x_mul_hd(rr, f256x_add(F[2 * t], F[2 * t + 1])));
                    nb[t] = f256x_add(B[2 * t], f256x_mul_hd(rr, f256x_add(B[2 * t], B[2 * t + 1])));
                }
                F.swap(nf);
                B.swap(nb);
            }
            observe_msg(j + 1 == k && i + 1 != r ? do_switch() : msg_ext(F, B));
        }
        int ext_dim = split_dim - k;
        int level = i + 1;
        if (i + 1 == r) {
            yr.resize(2 * F.size());
            memcpy(yr.data(), F.data(), yr.size() * sizeof(F128));
            for (const F128& v : yr) ch.observe_f128(toch(v));
            std::vector<size_t> qs;
            std::vector<F128> alpha;
            query_phase(level, opens[n_opens - 1], qs, alpha);
            ChF128 bc;
            c_nonces.push_back(ch.grind_pow_and_sample_f128((uint32_t)cbits[level], &bc));
            break;
        }
        split_dim = ext_dim + 1;
        Committed next = commit_level(i + 2);
        level_oods(i + 2);
        std::vector<size_t> qs;
        std::vector<F128> alpha;
        query_phase(level, opens[level], qs, alpha);
        induce_introduce_glue(ext_dim, i + 2, qs, alpha);
        prev_cw = std::move(next.cw);
        prev_tree = std::move(next.tree);
        prev_bl = next.bl;
        prev_lanes = next.lanes;
    }

    // ---- diff against the Rust proof ----
    if (rcaps.size() != e_rcaps.size()) { printf("rcaps count\n"); return 1; }
    for (size_t l = 0; l < e_rcaps.size(); l++) {
        if (rcaps[l].size() != e_rcaps[l].size()) { printf("rcap[%zu] size\n", l); return 1; }
        for (size_t i = 0; i < e_rcaps[l].size(); i++)
            if (!mhash_eq(rcaps[l][i], e_rcaps[l][i])) { printf("rcap[%zu][%zu] differs\n", l, i); return 1; }
    }
    printf("  recursive caps: OK (%zu)\n", rcaps.size());
    for (uint32_t oi = 0; oi < n_opens; oi++) {
        const ExpOpen &e = e_opens[oi], &g = opens[oi];
        if (e.n_rows != g.n_rows || e.row_len != g.row_len) {
            printf("open[%u] shape got %ux%u exp %ux%u\n", oi, g.n_rows, g.row_len, e.n_rows, e.row_len);
            return 1;
        }
        for (size_t i = 0; i < e.rows.size(); i++)
            if (!eq128(e.rows[i], g.rows[i])) { printf("open[%u] row word %zu differs\n", oi, i); return 1; }
        if (e.path.size() != g.path.size()) { printf("open[%u] path len\n", oi); return 1; }
        for (size_t i = 0; i < e.path.size(); i++)
            if (!mhash_eq(e.path[i], g.path[i])) { printf("open[%u] path hash %zu differs\n", oi, i); return 1; }
    }
    printf("  opens + capped paths: OK (%u)\n", n_opens);
    if (yr.size() != e_yr.size()) { printf("yr size\n"); return 1; }
    for (size_t i = 0; i < e_yr.size(); i++)
        if (!eq128(yr[i], e_yr[i])) { printf("yr[%zu] differs\n", i); return 1; }
    printf("  yr: OK (%zu)\n", yr.size());
    if (transcript.size() != n_tx) { printf("transcript count got %zu exp %u\n", transcript.size(), n_tx); return 1; }
    for (size_t i = 0; i < transcript.size(); i++) {
        const F128 got[4] = {transcript[i].u0.c0, transcript[i].u0.c1, transcript[i].u2.c0,
                             transcript[i].u2.c1};
        for (int j = 0; j < 4; j++)
            if (!eq128(got[j], e_tx[4 * i + j])) {
                printf("transcript msg %zu limb %d differs\n", i, j);
                return 1;
            }
    }
    printf("  sumcheck_transcript_f256: OK (%u msgs)\n", n_tx);
    if (ood_values.size() != e_ood.size()) { printf("ood count\n"); return 1; }
    for (size_t i = 0; i < e_ood.size(); i++)
        if (!eq128(ood_values[i], e_ood[i])) { printf("ood[%zu] differs\n", i); return 1; }
    auto diff_n = [](const char* name, const std::vector<uint64_t>& got,
                     const std::vector<uint64_t>& exp) -> int {
        if (got.size() != exp.size()) { printf("%s count got %zu exp %zu\n", name, got.size(), exp.size()); return 1; }
        for (size_t i = 0; i < exp.size(); i++)
            if (got[i] != exp[i]) { printf("%s[%zu] got %llu exp %llu\n", name, i,
                                          (unsigned long long)got[i], (unsigned long long)exp[i]); return 1; }
        return 0;
    };
    if (diff_n("grinding_nonces", g_nonces, e_gn)) return 1;
    if (diff_n("claim_batch_nonces", c_nonces, e_cn)) return 1;
    if (diff_n("consistency_batch_nonces", x_nonces, e_xn)) return 1;
    printf("  ood values + all three nonce families: OK\n");
    printf("LIGERITO-F256-HOST OK: the host ladder replay matches the real F256 driver "
           "on every proof field (m=%u)\n", m);
    return 0;
}
