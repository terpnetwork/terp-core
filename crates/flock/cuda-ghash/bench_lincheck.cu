// Throughput baseline for the lincheck prover kernels (GPU port of
// src/lincheck.rs). No oracle — correctness is validated by test_lincheck;
// here we only time, with inputs generated on-device / on-host.
//
// Phases timed (mirrors prove_padded_inner), with k = 2^k_log, n_log = m - k_log:
//   - csc_fold        : α-batched CSC column marginal → comb_vec (len k).
//   - partial_fold    : reduce the full 2^m-bit witness → z_vec (len k). The
//                       bandwidth-dominant phase (reads 2^m/8 witness bytes).
//   - sumcheck        : inner_rest_len = k_log-k_skip top-bit product-sumcheck
//                       rounds over (comb_vec, z_vec); challenges precomputed
//                       (the real prover derives them host-side via Fiat-Shamir).
//
// Build:  make bench_lincheck
// Run:    ./bench_lincheck            (default sweep)
//         ./bench_lincheck 29 14 2 50 (m k_log k_skip iters)
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include "lincheck.cuh"

#define CK(x) do { cudaError_t e=(x); if(e){ \
    printf("CUDA error %s at %s:%d\n", cudaGetErrorString(e), __FILE__, __LINE__); \
    exit(1);} } while(0)

__global__ void fill_bytes(uint8_t* z, size_t n) {
    size_t i = blockIdx.x * (size_t)blockDim.x + threadIdx.x;
    if (i >= n) return;
    u64 x = (u64)i * 0x9E3779B97F4A7C15ull + 1;
    z[i] = (uint8_t)(x ^ (x >> 13) ^ (x >> 27));
}
__global__ void fill_f128(F128* a, long long n) {
    long long i = blockIdx.x * (long long)blockDim.x + threadIdx.x;
    if (i >= n) return;
    u64 x = (u64)i * 0x9E3779B97F4A7C15ull + 1;
    u64 y = x * 0xBF58476D1CE4E5B9ull;
    a[i] = F128{x, y};
}

static float time_ms(cudaEvent_t a, cudaEvent_t b) { float ms = 0; cudaEventElapsedTime(&ms, a, b); return ms; }

static void run_one(int m, int k_log, int k_skip, int iters) {
    int n_log = m - k_log;
    if (n_log < 3) { printf("skip m=%d k_log=%d (n_log<3)\n", m, k_log); return; }
    int k = 1 << k_log;
    int inner_rest_len = k_log - k_skip;
    long long n_outer = 1LL << n_log;
    long long n_stripes = n_outer / 8;
    size_t z_bytes = (size_t)1 << (m - 3);
    const int NNZ_PER_COL = 8;       // representative circuit density

    // ---- CSC matrices (host-generated, regular nnz/col, random rows).
    std::vector<uint32_t> a_col_ptr(k + 1), b_col_ptr(k + 1);
    std::vector<uint32_t> a_rows((size_t)k * NNZ_PER_COL), b_rows((size_t)k * NNZ_PER_COL);
    u64 s = 0xABCDEF;
    for (int c = 0; c <= k; c++) { a_col_ptr[c] = c * NNZ_PER_COL; b_col_ptr[c] = c * NNZ_PER_COL; }
    for (size_t i = 0; i < a_rows.size(); i++) { s = s * 6364136223846793005ull + 1; a_rows[i] = (uint32_t)((s >> 33) % k); }
    for (size_t i = 0; i < b_rows.size(); i++) { s = s * 6364136223846793005ull + 1; b_rows[i] = (uint32_t)((s >> 33) % k); }

    // ---- eq tables (host build, copied — matches the CPU prover's eq build).
    std::vector<F128> x_inner_rest(inner_rest_len), x_outer(n_log);
    for (int i = 0; i < inner_rest_len; i++) x_inner_rest[i] = F128{(u64)(i * 7 + 3), (u64)(i * 11 + 5)};
    for (int i = 0; i < n_log; i++) x_outer[i] = F128{(u64)(i * 13 + 1), (u64)(i * 17 + 9)};
    F128 z_skip{0x1234, 0x5678};
    F128 alpha{0x9abc, 0xdef0};
    std::vector<F128> eq_inner = build_quirky_eq_table_host(z_skip, x_inner_rest, k_skip);
    std::vector<F128> eq_outer = build_eq_table_host(x_outer);

    F128 *d_eq_inner, *d_comb, *d_zvec, *d_eq_outer, *d_nC, *d_nZ, *d_p1, *d_pinf, *d_e1, *d_einf;
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
    CK(cudaMalloc(&d_ar, a_rows.size() * sizeof(uint32_t)));
    CK(cudaMalloc(&d_bcp, (k + 1) * sizeof(uint32_t)));
    CK(cudaMalloc(&d_br, b_rows.size() * sizeof(uint32_t)));
    CK(cudaMalloc(&d_p1, LC_MAX_BLOCKS * sizeof(F128)));
    CK(cudaMalloc(&d_pinf, LC_MAX_BLOCKS * sizeof(F128)));
    CK(cudaMalloc(&d_e1, sizeof(F128)));
    CK(cudaMalloc(&d_einf, sizeof(F128)));

    CK(cudaMemcpy(d_eq_inner, eq_inner.data(), k * sizeof(F128), cudaMemcpyHostToDevice));
    CK(cudaMemcpy(d_eq_outer, eq_outer.data(), n_outer * sizeof(F128), cudaMemcpyHostToDevice));
    CK(cudaMemcpy(d_acp, a_col_ptr.data(), (k + 1) * sizeof(uint32_t), cudaMemcpyHostToDevice));
    CK(cudaMemcpy(d_ar, a_rows.data(), a_rows.size() * sizeof(uint32_t), cudaMemcpyHostToDevice));
    CK(cudaMemcpy(d_bcp, b_col_ptr.data(), (k + 1) * sizeof(uint32_t), cudaMemcpyHostToDevice));
    CK(cudaMemcpy(d_br, b_rows.data(), b_rows.size() * sizeof(uint32_t), cudaMemcpyHostToDevice));
    fill_bytes<<<(unsigned)((z_bytes + 255) / 256), 256>>>(d_zp, z_bytes);
    CK(cudaDeviceSynchronize());

    // Precomputed per-round challenges (values irrelevant for timing).
    std::vector<F128> chal(inner_rest_len);
    for (int r = 0; r < inner_rest_len; r++) chal[r] = F128{(u64)(r * 2654435761ull + 1), (u64)(r * 40503 + 7)};

    cudaEvent_t e0, e1ev, e2ev, e3ev;
    cudaEventCreate(&e0); cudaEventCreate(&e1ev); cudaEventCreate(&e2ev); cudaEventCreate(&e3ev);

    float t_csc = 0, t_pf = 0, t_sc = 0;
    for (int it = 0; it < iters; it++) {
        cudaEventRecord(e0);
        launch_linear_check_compressed_column_fold(d_eq_inner, d_acp, d_ar, d_bcp, d_br, alpha, k, d_comb);
        cudaEventRecord(e1ev);
        launch_linear_check_partial_fold(d_zp, d_eq_outer, n_stripes, k, k, d_zvec);
        cudaEventRecord(e2ev);
        // sumcheck cascade over fresh copies of comb/zvec each iter.
        F128 *cC = d_comb, *cZ = d_zvec, *nC = d_nC, *nZ = d_nZ;
        long long len = k;
        for (int r = 0; r < inner_rest_len; r++) {
            long long half = len / 2;
            launch_linear_check_message(cC, cZ, half, d_p1, d_pinf, d_e1, d_einf);
            launch_linear_check_fold_pair(cC, cZ, nC, nZ, half, chal[r]);
            F128* t; t = cC; cC = nC; nC = t; t = cZ; cZ = nZ; nZ = t;
            len = half;
        }
        cudaEventRecord(e3ev);
        cudaEventSynchronize(e3ev);
        t_csc += time_ms(e0, e1ev);
        t_pf += time_ms(e1ev, e2ev);
        t_sc += time_ms(e2ev, e3ev);
    }
    t_csc /= iters; t_pf /= iters; t_sc /= iters;
    double gib = z_bytes / (1024.0 * 1024.0 * 1024.0);
    printf("m=%2d k_log=%2d k_skip=%d | csc_fold %7.4f ms  partial_fold %7.4f ms (%.1f GB/s, %.2f GiB)  "
           "sumcheck %7.4f ms | total %7.4f ms\n",
           m, k_log, k_skip, t_csc, t_pf, gib / (t_pf / 1e3), gib, t_sc, t_csc + t_pf + t_sc);

    cudaEventDestroy(e0); cudaEventDestroy(e1ev); cudaEventDestroy(e2ev); cudaEventDestroy(e3ev);
    cudaFree(d_eq_inner); cudaFree(d_comb); cudaFree(d_zvec); cudaFree(d_nC); cudaFree(d_nZ);
    cudaFree(d_eq_outer); cudaFree(d_zp);
    cudaFree(d_acp); cudaFree(d_ar); cudaFree(d_bcp); cudaFree(d_br);
    cudaFree(d_p1); cudaFree(d_pinf); cudaFree(d_e1); cudaFree(d_einf);
}

int main(int argc, char** argv) {
    if (argc >= 4) {
        int m = atoi(argv[1]), k_log = atoi(argv[2]), k_skip = atoi(argv[3]);
        int iters = argc > 4 ? atoi(argv[4]) : 50;
        run_one(m, k_log, k_skip, iters);
        return 0;
    }
    // Default sweep: k_log/k_skip fixed, m grows (witness-bandwidth dominated).
    printf("lincheck kernel throughput (RTX 5090, sm_120)\n");
    for (int m = 24; m <= 30; m += 2) run_one(m, 14, 2, 30);
    return 0;
}
