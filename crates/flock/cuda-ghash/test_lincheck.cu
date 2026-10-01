// Bit-for-bit validation of the CUDA lincheck prover against the flock CPU
// oracle dumped by `src/bin/dump_lincheck_vectors.rs` (LNCK format).
//
// Drives the host FsChallenger (challenger.hpp) in lockstep with the real
// prover (observe label → sample α → … per-round messages → sample r →
// observe z_partial → sample r_inner_skip), and at every stage compares the
// device output to the golden value: α, comb_vec (CSC fold), z_vec (partial
// fold), each round's (e1, einf) + challenge r, z_partial, r_inner_skip, w.
//
// Build:  make test_lincheck
// Run:    (from repo root)
//           cargo run --release --bin dump_lincheck_vectors -- cuda-ghash/lincheck_vectors.bin 10 4 2 16
//         (from cuda-ghash/)
//           ./test_lincheck lincheck_vectors.bin
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include "lincheck.cuh"
#include "challenger.hpp"

#define CK(x) do { cudaError_t e=(x); if(e){ \
    printf("CUDA error %s at %s:%d\n", cudaGetErrorString(e), __FILE__, __LINE__); \
    exit(1);} } while(0)

static uint32_t rd_u32(FILE* f) {
    uint32_t v = 0;
    if (fread(&v, 4, 1, f) != 1) { printf("short read (u32)\n"); exit(1); }
    return v;
}
static F128 rd_f128(FILE* f) {
    u64 v[2];
    if (fread(v, 8, 2, f) != 2) { printf("short read (f128)\n"); exit(1); }
    return F128{v[0], v[1]};
}
static bool eq(F128 a, F128 b) { return a.lo == b.lo && a.hi == b.hi; }
static ChF128 to_ch(F128 x) { return ChF128{x.lo, x.hi}; }
static F128 from_ch(ChF128 x) { return F128{x.lo, x.hi}; }

static void fail(const char* what, int idx, F128 got, F128 exp) {
    printf("%s FAIL [%d]: got %016llx:%016llx exp %016llx:%016llx\n", what, idx,
           (unsigned long long)got.hi, (unsigned long long)got.lo,
           (unsigned long long)exp.hi, (unsigned long long)exp.lo);
    exit(1);
}

int main(int argc, char** argv) {
    const char* path = argc > 1 ? argv[1] : "lincheck_vectors.bin";
    FILE* f = fopen(path, "rb");
    if (!f) { printf("cannot open %s (run dump_lincheck_vectors first)\n", path); return 1; }

    if (rd_u32(f) != 0x4C4E434Bu) { printf("bad file (want LNCK magic)\n"); return 1; }
    int m = (int)rd_u32(f), k_log = (int)rd_u32(f), k_skip = (int)rd_u32(f);
    int useful_bits = (int)rd_u32(f);
    int n_log = m - k_log;
    int k = 1 << k_log;
    int inner_rest_len = k_log - k_skip;
    long long n_outer = 1LL << n_log;
    long long n_stripes = n_outer / 8;
    int k_skip_len = 1 << k_skip;

    uint32_t dlen = rd_u32(f);
    std::vector<uint8_t> domain(dlen);
    if (fread(domain.data(), 1, dlen, f) != dlen) { printf("short read (domain)\n"); return 1; }

    size_t z_bytes = (size_t)1 << (m - 3);
    std::vector<uint8_t> z_packed(z_bytes);
    if (fread(z_packed.data(), 1, z_bytes, f) != z_bytes) { printf("short read (z_packed)\n"); return 1; }

    uint32_t a_nnz = rd_u32(f);
    std::vector<uint32_t> a_col_ptr(k + 1), a_rows(a_nnz);
    for (auto& v : a_col_ptr) v = rd_u32(f);
    for (auto& v : a_rows) v = rd_u32(f);
    uint32_t b_nnz = rd_u32(f);
    std::vector<uint32_t> b_col_ptr(k + 1), b_rows(b_nnz);
    for (auto& v : b_col_ptr) v = rd_u32(f);
    for (auto& v : b_rows) v = rd_u32(f);

    F128 z_skip = rd_f128(f);
    std::vector<F128> x_inner_rest(inner_rest_len), x_outer(n_log);
    for (auto& v : x_inner_rest) v = rd_f128(f);
    for (auto& v : x_outer) v = rd_f128(f);

    F128 g_alpha = rd_f128(f);
    std::vector<F128> g_comb(k), g_zvec(k);
    for (auto& v : g_comb) v = rd_f128(f);
    for (auto& v : g_zvec) v = rd_f128(f);
    std::vector<F128> g_e1(inner_rest_len), g_einf(inner_rest_len), g_r(inner_rest_len);
    for (int i = 0; i < inner_rest_len; i++) { g_e1[i] = rd_f128(f); g_einf[i] = rd_f128(f); g_r[i] = rd_f128(f); }
    std::vector<F128> g_zpart(k_skip_len);
    for (auto& v : g_zpart) v = rd_f128(f);
    F128 g_r_skip = rd_f128(f);
    F128 g_w = rd_f128(f);
    fclose(f);

    printf("LNCK: m=%d k_log=%d k_skip=%d useful_bits=%d n_log=%d rounds=%d nnz_a=%u nnz_b=%u\n",
           m, k_log, k_skip, useful_bits, n_log, inner_rest_len, a_nnz, b_nnz);

    // ---- Challenger: replay the prover's transcript prefix.
    FsChallenger ch(domain.data(), dlen);
    ch.observe_label((const uint8_t*)"flock-lincheck-v0", 17);
    F128 alpha = from_ch(ch.sample_f128());
    if (!eq(alpha, g_alpha)) fail("ALPHA", 0, alpha, g_alpha);

    // ---- Device buffers.
    F128 *d_eq_inner, *d_comb, *d_zvec, *d_eq_outer;
    F128 *d_nC, *d_nZ, *d_p1, *d_pinf, *d_e1, *d_einf;
    uint8_t* d_zp;
    uint32_t *d_acp, *d_ar, *d_bcp, *d_br;
    CK(cudaMalloc(&d_eq_inner, k * sizeof(F128)));
    CK(cudaMalloc(&d_comb, k * sizeof(F128)));
    CK(cudaMalloc(&d_zvec, k * sizeof(F128)));
    CK(cudaMalloc(&d_nC, k * sizeof(F128)));
    CK(cudaMalloc(&d_nZ, k * sizeof(F128)));
    CK(cudaMalloc(&d_eq_outer, n_outer * sizeof(F128)));
    CK(cudaMalloc(&d_zp, z_bytes));
    CK(cudaMalloc(&d_acp, (k + 1) * sizeof(uint32_t)));
    CK(cudaMalloc(&d_ar, (a_nnz ? a_nnz : 1) * sizeof(uint32_t)));
    CK(cudaMalloc(&d_bcp, (k + 1) * sizeof(uint32_t)));
    CK(cudaMalloc(&d_br, (b_nnz ? b_nnz : 1) * sizeof(uint32_t)));
    CK(cudaMalloc(&d_p1, LC_MAX_BLOCKS * sizeof(F128)));
    CK(cudaMalloc(&d_pinf, LC_MAX_BLOCKS * sizeof(F128)));
    CK(cudaMalloc(&d_e1, sizeof(F128)));
    CK(cudaMalloc(&d_einf, sizeof(F128)));

    // ---- eq_inner (host quirky build) → CSC fold → comb_vec.
    std::vector<F128> eq_inner = build_quirky_eq_table_host(z_skip, x_inner_rest, k_skip);
    CK(cudaMemcpy(d_eq_inner, eq_inner.data(), k * sizeof(F128), cudaMemcpyHostToDevice));
    CK(cudaMemcpy(d_acp, a_col_ptr.data(), (k + 1) * sizeof(uint32_t), cudaMemcpyHostToDevice));
    if (a_nnz) CK(cudaMemcpy(d_ar, a_rows.data(), a_nnz * sizeof(uint32_t), cudaMemcpyHostToDevice));
    CK(cudaMemcpy(d_bcp, b_col_ptr.data(), (k + 1) * sizeof(uint32_t), cudaMemcpyHostToDevice));
    if (b_nnz) CK(cudaMemcpy(d_br, b_rows.data(), b_nnz * sizeof(uint32_t), cudaMemcpyHostToDevice));
    launch_linear_check_compressed_column_fold(d_eq_inner, d_acp, d_ar, d_bcp, d_br, alpha, k, d_comb);
    CK(cudaGetLastError());
    std::vector<F128> comb(k);
    CK(cudaMemcpy(comb.data(), d_comb, k * sizeof(F128), cudaMemcpyDeviceToHost));
    for (int c = 0; c < k; c++) if (!eq(comb[c], g_comb[c])) fail("COMB", c, comb[c], g_comb[c]);
    printf("  comb_vec  OK (%d cols)\n", k);

    // ---- partial fold → z_vec.
    std::vector<F128> eq_outer = build_eq_table_host(x_outer);
    CK(cudaMemcpy(d_eq_outer, eq_outer.data(), n_outer * sizeof(F128), cudaMemcpyHostToDevice));
    CK(cudaMemcpy(d_zp, z_packed.data(), z_bytes, cudaMemcpyHostToDevice));
    launch_linear_check_partial_fold(d_zp, d_eq_outer, n_stripes, k, useful_bits, d_zvec);
    CK(cudaGetLastError());
    std::vector<F128> zvec(k);
    CK(cudaMemcpy(zvec.data(), d_zvec, k * sizeof(F128), cudaMemcpyDeviceToHost));
    for (int i = 0; i < k; i++) if (!eq(zvec[i], g_zvec[i])) fail("ZVEC", i, zvec[i], g_zvec[i]);
    printf("  z_vec     OK (%d rows)\n", k);

    // ---- top-bit product-sumcheck rounds.
    F128 *cC = d_comb, *cZ = d_zvec, *nC = d_nC, *nZ = d_nZ;
    long long len = k;
    for (int rnd = 0; rnd < inner_rest_len; rnd++) {
        long long half = len / 2;
        launch_linear_check_message(cC, cZ, half, d_p1, d_pinf, d_e1, d_einf);
        CK(cudaGetLastError());
        F128 e1, einf;
        CK(cudaMemcpy(&e1, d_e1, sizeof(F128), cudaMemcpyDeviceToHost));
        CK(cudaMemcpy(&einf, d_einf, sizeof(F128), cudaMemcpyDeviceToHost));
        if (!eq(e1, g_e1[rnd])) fail("MSG e1", rnd, e1, g_e1[rnd]);
        if (!eq(einf, g_einf[rnd])) fail("MSG einf", rnd, einf, g_einf[rnd]);
        ch.observe_f128(to_ch(e1));
        ch.observe_f128(to_ch(einf));
        F128 r = from_ch(ch.sample_f128());
        if (!eq(r, g_r[rnd])) fail("CHAL r", rnd, r, g_r[rnd]);
        launch_linear_check_fold_pair(cC, cZ, nC, nZ, half, r);
        CK(cudaGetLastError());
        CK(cudaDeviceSynchronize());
        F128* t;
        t = cC; cC = nC; nC = t;
        t = cZ; cZ = nZ; nZ = t;
        len = half;
        printf("  round %2d  len %6lld -> %6lld  msg+fold OK\n", rnd, len * 2, len);
    }

    // ---- z_partial (collapsed z_vec, length 2^k_skip).
    if (len != k_skip_len) { printf("len %lld != 2^k_skip %d\n", len, k_skip_len); return 1; }
    std::vector<F128> zpart(k_skip_len);
    CK(cudaMemcpy(zpart.data(), cZ, k_skip_len * sizeof(F128), cudaMemcpyDeviceToHost));
    for (int i = 0; i < k_skip_len; i++) if (!eq(zpart[i], g_zpart[i])) fail("ZPART", i, zpart[i], g_zpart[i]);
    printf("  z_partial OK (%d)\n", k_skip_len);

    std::vector<ChF128> zpart_ch(k_skip_len);
    for (int i = 0; i < k_skip_len; i++) zpart_ch[i] = to_ch(zpart[i]);
    ch.observe_f128_slice(zpart_ch.data(), k_skip_len);
    F128 r_skip = from_ch(ch.sample_f128());
    if (!eq(r_skip, g_r_skip)) fail("R_SKIP", 0, r_skip, g_r_skip);

    // ---- w = Σ lagrange(k_skip, r_skip)·z_partial.
    std::vector<F128> lambda = lagrange_weights_host(k_skip, r_skip);
    F128 w = inner_product_host(lambda, zpart);
    if (!eq(w, g_w)) fail("W", 0, w, g_w);

    printf("LINCHECK OK: comb_vec + z_vec + %d sumcheck rounds + z_partial + claim (r_inner_skip, w) "
           "match flock bit-for-bit\n", inner_rest_len);
    return 0;
}
