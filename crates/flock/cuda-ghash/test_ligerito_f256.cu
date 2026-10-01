// Byte-for-byte validation of the F256 Ligerito ladder port
// (ligerito_f256.cuh — the "flock-ligerito-basis-f256-split-v0" transcript)
// against the REAL Rust driver, via the oracle dumped by
// src/bin/dump_ligerito_f256_vectors.rs ("LF25" format).
//
// The test rebuilds the L0 commit on the GPU (fused NTT + Merkle) and checks
// its cap against the dump, computes the round-0 message on device, then runs
// the complete ladder — folds, code switches, recursive commits, OODs,
// stratified query phases, capped paths, induce/introduce, every PoW nonce —
// and diffs EVERY proof field against the Rust prover's own output.
//
// Build:  make test_ligerito_f256
// Run:    (repo root)  cargo run --release --bin dump_ligerito_f256_vectors -- \
//                        cuda-ghash/ligerito_f256_vectors.bin 22
//         (cuda-ghash) ./test_ligerito_f256 ligerito_f256_vectors.bin
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include "ntt_f128.cuh"
#include "merkle.cuh"
#include "sumcheck_ab.cuh"
#include "ligerito_f256.cuh"

#define TCK(x) do { cudaError_t e = (x); if (e != cudaSuccess) { \
    printf("CUDA error %s at %s:%d\n", cudaGetErrorString(e), __FILE__, __LINE__); return 1; } } while (0)

static uint32_t rd_u32(FILE* f) { uint32_t v; if (fread(&v, 4, 1, f) != 1) { printf("short read u32\n"); exit(1); } return v; }
static uint64_t rd_u64(FILE* f) { uint64_t v; if (fread(&v, 8, 1, f) != 1) { printf("short read u64\n"); exit(1); } return v; }
static F128 rd_f128(FILE* f) { F128 v; if (fread(&v, 16, 1, f) != 1) { printf("short read f128\n"); exit(1); } return v; }
static MHash rd_hash(FILE* f) { MHash h; if (fread(h.b, 1, 32, f) != 32) { printf("short read hash\n"); exit(1); } return h; }
static bool eq128(F128 a, F128 b) { return a.lo == b.lo && a.hi == b.hi; }

struct ExpOpen { std::vector<F128> rows; uint32_t n_rows, row_len; std::vector<MHash> path; };

static ExpOpen rd_open(FILE* f) {
    ExpOpen o;
    o.n_rows = rd_u32(f);
    o.row_len = rd_u32(f);
    o.rows.resize((size_t)o.n_rows * o.row_len);
    for (auto& x : o.rows) x = rd_f128(f);
    uint32_t np = rd_u32(f);
    o.path.resize(np);
    for (auto& h : o.path) h = rd_hash(f);
    return o;
}

static int diff_open(const char* name, const ExpOpen& e, const LigLevelOpen& g) {
    if (e.n_rows != g.n_rows || e.row_len != g.row_len) {
        printf("%s: shape got %zux%zu exp %ux%u\n", name, g.n_rows, g.row_len, e.n_rows, e.row_len);
        return 1;
    }
    for (size_t i = 0; i < e.rows.size(); i++)
        if (!eq128(e.rows[i], g.rows_flat[i])) { printf("%s: row word %zu differs\n", name, i); return 1; }
    if (e.path.size() != g.path.size()) {
        printf("%s: path len got %zu exp %zu\n", name, g.path.size(), e.path.size());
        return 1;
    }
    for (size_t i = 0; i < e.path.size(); i++)
        if (!mhash_eq(e.path[i], g.path[i])) { printf("%s: path hash %zu differs\n", name, i); return 1; }
    return 0;
}

int main(int argc, char** argv) {
    const char* path = argc > 1 ? argv[1] : "ligerito_f256_vectors.bin";
    FILE* f = fopen(path, "rb");
    if (!f) { printf("cannot open %s (run dump_ligerito_f256_vectors first)\n", path); return 1; }
    if (rd_u32(f) != 0x3532464Cu) { printf("bad file (want LF25)\n"); return 1; }
    uint32_t dlen = rd_u32(f);
    std::vector<uint8_t> domain(dlen);
    if (fread(domain.data(), 1, dlen, f) != dlen) { printf("short read domain\n"); return 1; }
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
    std::vector<F128> h_f(len), h_b(len);
    for (auto& x : h_f) x = rd_f128(f);
    for (auto& x : h_b) x = rd_f128(f);
    F128 target = rd_f128(f);

    // expected proof
    uint32_t n_icap = rd_u32(f);
    std::vector<MHash> e_icap(n_icap);
    for (auto& h : e_icap) h = rd_hash(f);
    uint32_t n_rcaps = rd_u32(f);
    std::vector<std::vector<MHash>> e_rcaps(n_rcaps);
    for (auto& cap : e_rcaps) { cap.resize(rd_u32(f)); for (auto& h : cap) h = rd_hash(f); }
    uint32_t n_opens = rd_u32(f);
    std::vector<ExpOpen> e_opens(n_opens);
    for (auto& o : e_opens) o = rd_open(f);
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
    printf("LF25: m=%u log_n=%d initial_k=%d r=%d (%u tx msgs, %u oods)\n", m, log_n, initial_k, r,
           n_tx, n_ood);

    // ---- upload + L0 commit on the GPU ----
    F128 *d_f, *d_b, *d_cw0;
    uint8_t* d_tree0;
    TCK(cudaMalloc(&d_f, len * sizeof(F128)));
    TCK(cudaMalloc(&d_b, len * sizeof(F128)));
    TCK(cudaMemcpy(d_f, h_f.data(), len * sizeof(F128), cudaMemcpyHostToDevice));
    TCK(cudaMemcpy(d_b, h_b.data(), len * sizeof(F128), cudaMemcpyHostToDevice));
    int k_code = (log_n - initial_k) + rates[0];
    int num_ntts = 1 << initial_k;
    if ((1LL << k_code) != l0_bl || num_ntts != l0_lanes) {
        printf("L0 shape mismatch: k_code=%d lanes=%d vs dump %lld/%d\n", k_code, num_ntts, l0_bl,
               l0_lanes);
        return 1;
    }
    const TwiddleTable* tt;
    F128* d_tw;
    TCK(lf_get_twiddles(k_code, tt, d_tw));
    TCK(cudaMalloc(&d_cw0, (size_t)(l0_bl * num_ntts) * sizeof(F128)));
    TCK(cudaMalloc(&d_tree0, (size_t)(2 * l0_bl - 1) * 32));
    if (!ntt_can_fuse_source(k_code - rates[0])) { printf("unfused L0 not wired\n"); return 1; }
    launch_ntt(d_cw0, d_tw, *tt, rates[0], k_code, num_ntts, 256, d_f, len - 1);
    TCK(cudaGetLastError());
    launch_merkle((const uint8_t*)d_cw0, d_tree0, l0_bl, num_ntts * 16);
    TCK(cudaDeviceSynchronize());

    // ---- round-0 message over (f, b) ----
    F128 first_u0, first_u2;
    {
        F128 *p0, *p2, *du0, *du2;
        TCK(cudaMalloc(&p0, SMC_MAX_BLOCKS * sizeof(F128)));
        TCK(cudaMalloc(&p2, SMC_MAX_BLOCKS * sizeof(F128)));
        TCK(cudaMalloc(&du0, sizeof(F128)));
        TCK(cudaMalloc(&du2, sizeof(F128)));
        launch_sumcheck_message(d_f, d_b, len / 2, p0, p2, du0, du2);
        TCK(cudaGetLastError());
        TCK(cudaMemcpy(&first_u0, du0, sizeof(F128), cudaMemcpyDeviceToHost));
        TCK(cudaMemcpy(&first_u2, du2, sizeof(F128), cudaMemcpyDeviceToHost));
        cudaFree(p0); cudaFree(p2); cudaFree(du0); cudaFree(du2);
    }

    // ---- the ladder ----
    FsChallenger ch(domain.data(), dlen);
    LigF256Config C;
    C.log_n = log_n;
    C.initial_k = initial_k;
    C.recursive_steps = r;
    C.log_inv_rates = rates.data();
    C.recursive_ks = ks.data();
    C.queries = queries.data();
    C.grinding_bits = gbits.data();
    C.claim_batch_grinding_bits = cbits.data();
    C.consistency_batch_grinding_bits = xbits.data();
    C.ood_samples = oods.data();
    LigF256Proof lig;
    int rc = run_ligerito_f256(C, ch, target, first_u0, first_u2, d_f, d_b, d_cw0, d_tree0, l0_bl,
                               l0_lanes, lig_default_alloc(), lig);
    if (rc != 0) { printf("run_ligerito_f256 failed (%d)\n", rc); return 1; }

    // ---- diff every field ----
    if (lig.initial_cap.size() != e_icap.size()) { printf("initial_cap size\n"); return 1; }
    for (size_t i = 0; i < e_icap.size(); i++)
        if (!mhash_eq(lig.initial_cap[i], e_icap[i])) { printf("initial_cap[%zu] differs (L0 commit)\n", i); return 1; }
    printf("  initial_cap: OK (%zu)\n", e_icap.size());
    if (lig.recursive_caps.size() != e_rcaps.size()) { printf("recursive_caps count\n"); return 1; }
    for (size_t l = 0; l < e_rcaps.size(); l++) {
        if (lig.recursive_caps[l].size() != e_rcaps[l].size()) { printf("rcap[%zu] size\n", l); return 1; }
        for (size_t i = 0; i < e_rcaps[l].size(); i++)
            if (!mhash_eq(lig.recursive_caps[l][i], e_rcaps[l][i])) { printf("rcap[%zu][%zu] differs\n", l, i); return 1; }
    }
    printf("  recursive_caps: OK (%zu)\n", e_rcaps.size());
    uint32_t got_opens = (uint32_t)(2 + lig.recursive_opens.size());
    if (got_opens != n_opens) { printf("opens count got %u exp %u\n", got_opens, n_opens); return 1; }
    if (diff_open("open[L0]", e_opens[0], lig.initial_open)) return 1;
    for (size_t i = 0; i < lig.recursive_opens.size(); i++) {
        char name[32];
        snprintf(name, sizeof name, "open[L%zu]", i + 1);
        if (diff_open(name, e_opens[i + 1], lig.recursive_opens[i])) return 1;
    }
    if (diff_open("open[final]", e_opens[n_opens - 1], lig.final_open)) return 1;
    printf("  opens + capped paths: OK (%u)\n", n_opens);
    if (lig.yr.size() != e_yr.size()) { printf("yr size\n"); return 1; }
    for (size_t i = 0; i < e_yr.size(); i++)
        if (!eq128(lig.yr[i], e_yr[i])) { printf("yr[%zu] differs\n", i); return 1; }
    printf("  yr: OK (%zu)\n", e_yr.size());
    if (lig.transcript.size() != n_tx) { printf("transcript count got %zu exp %u\n", lig.transcript.size(), n_tx); return 1; }
    for (size_t i = 0; i < lig.transcript.size(); i++) {
        const F128 got[4] = {lig.transcript[i].u0.c0, lig.transcript[i].u0.c1,
                             lig.transcript[i].u2.c0, lig.transcript[i].u2.c1};
        for (int j = 0; j < 4; j++)
            if (!eq128(got[j], e_tx[4 * i + j])) {
                printf("transcript msg %zu limb %d differs: got %016llx:%016llx exp %016llx:%016llx\n",
                       i, j, (unsigned long long)got[j].hi, (unsigned long long)got[j].lo,
                       (unsigned long long)e_tx[4 * i + j].hi, (unsigned long long)e_tx[4 * i + j].lo);
                return 1;
            }
    }
    printf("  sumcheck_transcript_f256: OK (%u msgs)\n", n_tx);
    if (lig.ood_values.size() != e_ood.size()) { printf("ood count\n"); return 1; }
    for (size_t i = 0; i < e_ood.size(); i++)
        if (!eq128(lig.ood_values[i], e_ood[i])) { printf("ood[%zu] differs\n", i); return 1; }
    auto diff_nonces = [](const char* name, const std::vector<uint64_t>& got,
                          const std::vector<uint64_t>& exp) -> int {
        if (got.size() != exp.size()) { printf("%s count got %zu exp %zu\n", name, got.size(), exp.size()); return 1; }
        for (size_t i = 0; i < exp.size(); i++)
            if (got[i] != exp[i]) { printf("%s[%zu]: got %llu exp %llu\n", name, i,
                                           (unsigned long long)got[i], (unsigned long long)exp[i]); return 1; }
        return 0;
    };
    if (diff_nonces("grinding_nonces", lig.grinding_nonces, e_gn)) return 1;
    if (diff_nonces("claim_batch_nonces", lig.claim_batch_nonces, e_cn)) return 1;
    if (diff_nonces("consistency_batch_nonces", lig.consistency_batch_nonces, e_xn)) return 1;
    printf("  ood values + all three nonce families: OK\n");

    cudaFree(d_f); cudaFree(d_b); cudaFree(d_cw0); cudaFree(d_tree0);
    printf("LIGERITO-F256 OK: the GPU ladder matches the real F256 driver on every proof field (m=%u)\n", m);
    return 0;
}
