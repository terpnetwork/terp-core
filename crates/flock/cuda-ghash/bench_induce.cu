// Throughput baseline for the induce_sumcheck_poly accumulation kernel (GPU
// pcs::open / Ligerito. No oracle. Correctness is
// validated by test_induce; here we only time the dominant device kernel:
//   basis_poly[h·low_n + l] = Σ_i scaled_high[i][h] · low_i[l]     (deferred reduce)
// over n = 2^log_n outputs, n_queries terms each (O(n·n_queries) muls). Inputs
// are synthesized on-device (values irrelevant for timing).
//
// The host setup (qtensor builds etc.) is small and not timed here.
//
// Build:  make bench_induce
// Run:    ./bench_induce 22 243 [iters]   (log_n n_queries; default sweep if no args)
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include "induce_sumcheck.cuh"

#define CK(x) do { cudaError_t e=(x); if(e){ \
    printf("CUDA error %s at %s:%d\n", cudaGetErrorString(e), __FILE__, __LINE__); \
    exit(1);} } while(0)

__global__ void fill_f128(F128* d, long long n, u64 seed) {
    long long i = blockIdx.x * (long long)blockDim.x + threadIdx.x;
    if (i >= n) return;
    u64 x = ((u64)i + seed) * 0x9E3779B97F4A7C15ull + 1;
    d[i] = F128{x, x * 0xBF58476D1CE4E5B9ull};
}

static void run_one(int log_n, int n_queries, int iters) {
    int low_bits = log_n / 2, high_bits = log_n - low_bits;
    int low_n = 1 << low_bits, high_n = 1 << high_bits;
    long long n = 1LL << log_n;

    F128 *d_low, *d_sh, *d_basis;
    CK(cudaMalloc(&d_low, (size_t)n_queries * low_n * sizeof(F128)));
    CK(cudaMalloc(&d_sh, (size_t)n_queries * high_n * sizeof(F128)));
    CK(cudaMalloc(&d_basis, (size_t)n * sizeof(F128)));

    int tpb = 256;
    fill_f128<<<(unsigned)(((long long)n_queries * low_n + tpb - 1) / tpb), tpb>>>(d_low, (long long)n_queries * low_n, 1);
    fill_f128<<<(unsigned)(((long long)n_queries * high_n + tpb - 1) / tpb), tpb>>>(d_sh, (long long)n_queries * high_n, 2);
    CK(cudaGetLastError());

    double muls = (double)n * n_queries;
    launch_induce_accumulate(d_sh, d_low, n_queries, low_n, high_n, d_basis, n); // warm-up
    CK(cudaDeviceSynchronize());
    cudaEvent_t a, b; CK(cudaEventCreate(&a)); CK(cudaEventCreate(&b));
    CK(cudaEventRecord(a));
    for (int it = 0; it < iters; it++)
        launch_induce_accumulate(d_sh, d_low, n_queries, low_n, high_n, d_basis, n);
    CK(cudaEventRecord(b));
    CK(cudaEventSynchronize(b));
    float ms_total = 0; CK(cudaEventElapsedTime(&ms_total, a, b));
    double ms = ms_total / iters;
    double basis_gib = n * 16.0 / (1024.0 * 1024.0 * 1024.0);
    double in_mib = (double)n_queries * (low_n + high_n) * 16.0 / (1024.0 * 1024.0);

    printf("  log_n=%-2d n_queries=%-3d basis=%6.3f GiB in=%6.1f MiB | %8.3f ms  %8.2f GMul/s\n",
           log_n, n_queries, basis_gib, in_mib, ms, muls / (ms * 1e-3) / 1e9);
    CK(cudaEventDestroy(a)); CK(cudaEventDestroy(b));

    cudaFree(d_low); cudaFree(d_sh); cudaFree(d_basis);
}

int main(int argc, char** argv) {
    int dev = 0; cudaDeviceProp p; CK(cudaGetDeviceProperties(&p, dev));
    printf("Device: %s | %d SMs | sm_%d%d\n\n", p.name, p.multiProcessorCount, p.major, p.minor);

    if (argc >= 3) {
        int log_n = atoi(argv[1]), nq = atoi(argv[2]);
        int iters = argc >= 4 ? atoi(argv[3]) : 20;
        printf("== induce accumulate (reduce-per-term), %d iters ==\n", iters);
        run_one(log_n, nq, iters);
        return 0;
    }

    printf("== induce accumulate (reduce-per-term), n_queries=243 (rate 1/2) ==\n");
    for (int log_n = 16; log_n <= 24; log_n += 2) run_one(log_n, 243, log_n >= 22 ? 10 : 20);
    return 0;
}
