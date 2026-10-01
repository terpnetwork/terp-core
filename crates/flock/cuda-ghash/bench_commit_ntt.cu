// Throughput baseline for the correctness-first interleaved additive-NTT
// kernel (P2). No oracle needed — correctness is validated separately by
// test_commit_ntt; here we only time. The codeword is generated on-device, so
// this scales to realistic m (no 256 MB golden files).
//
// Params follow src/pcs/commit.rs (LOG_PACKING = 7):
//   log_msg_len  = m - 7
//   log_dim      = log_msg_len - log_batch_size
//   k_code       = log_dim + log_inv_rate        (= per-lane log_d == L)
//   num_ntts     = 2^log_batch_size
//   codeword_len = 2^k_code * num_ntts = 2^(log_msg_len + log_inv_rate)
//
// The forward transform runs layers [log_inv_rate, k_code); the first
// log_inv_rate layers are the replicate-fill copies, skipped (as in commit).
//
// Build:  make bench_commit_ntt
// Run:    ./bench_commit_ntt 29 1 5 [iters]   (default sweep if no args)
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include "ntt_f128.cuh"

#define CK(x) do { cudaError_t e=(x); if(e){ \
    printf("CUDA error %s at %s:%d\n", cudaGetErrorString(e), __FILE__, __LINE__); \
    exit(1);} } while(0)

// Deterministic on-device fill (any bit pattern is a valid F128).
__global__ void fill_benchmark_input(F128* d, long long n) {
    long long i = blockIdx.x * (long long)blockDim.x + threadIdx.x;
    if (i >= n) return;
    u64 x = (u64)i * 0x9E3779B97F4A7C15ull + 1;
    d[i] = F128{x, x * 0xBF58476D1CE4E5B9ull};
}

static void run_one(int m, int log_inv_rate, int log_batch_size, int iters) {
    const int LOG_PACKING = 7;
    int log_msg_len = m - LOG_PACKING;
    int log_dim     = log_msg_len - log_batch_size;
    int k_code      = log_dim + log_inv_rate;        // == log_d == L
    int num_ntts    = 1 << log_batch_size;
    long long codeword_len = (1LL << k_code) * (long long)num_ntts;
    int n_layers = k_code - log_inv_rate;            // == log_dim

    double gib = codeword_len * 16.0 / (1024.0 * 1024.0 * 1024.0);

    F128 *d_data = nullptr, *d_tw = nullptr;
    CK(cudaMalloc(&d_data, codeword_len * sizeof(F128)));
    TwiddleTable tt = build_twiddle_table(k_code);
    CK(cudaMalloc(&d_tw, tt.data.size() * sizeof(F128)));
    CK(cudaMemcpy(d_tw, tt.data.data(), tt.data.size() * sizeof(F128), cudaMemcpyHostToDevice));

    constexpr int tpb = 256;
    long long fill_blocks = (codeword_len + tpb - 1) / tpb;
    fill_benchmark_input<<<(unsigned)fill_blocks, tpb>>>(d_data, codeword_len);
    CK(cudaGetLastError());

    auto run_transform = [&]() {
        launch_ntt(d_data, d_tw, tt, log_inv_rate, k_code, num_ntts, tpb);
    };

    // Warm-up.
    run_transform();
    CK(cudaDeviceSynchronize());

    cudaEvent_t a, b; CK(cudaEventCreate(&a)); CK(cudaEventCreate(&b));
    CK(cudaEventRecord(a));
    for (int it = 0; it < iters; it++) run_transform();
    CK(cudaEventRecord(b));
    CK(cudaEventSynchronize(b));
    float ms_total = 0; CK(cudaEventElapsedTime(&ms_total, a, b));
    double ms = ms_total / iters;

    // Total field muls per transform = n_layers * (codeword_len / 2).
    double muls = (double)n_layers * (double)codeword_len / 2.0;
    double gmuls = muls / (ms * 1e-3) / 1e9;
    // Bytes moved per transform: each layer reads + writes the whole buffer.
    double gbps = (double)n_layers * codeword_len * 32.0 / (ms * 1e-3) / 1e9;

    printf("  m=%-2d rate=1/%-2d batch=%d | k_code=%2d num_ntts=%-2d buf=%6.3f GiB layers=%2d | "
           "%8.3f ms  %7.2f GMul/s  %7.1f GB/s\n",
           m, 1 << log_inv_rate, log_batch_size, k_code, num_ntts, gib, n_layers, ms, gmuls, gbps);

    CK(cudaEventDestroy(a)); CK(cudaEventDestroy(b));
    cudaFree(d_data); cudaFree(d_tw);
}

int main(int argc, char** argv) {
    int dev = 0; cudaDeviceProp p; CK(cudaGetDeviceProperties(&p, dev));
    printf("Device: %s | %d SMs | sm_%d%d\n\n", p.name, p.multiProcessorCount, p.major, p.minor);

    if (argc >= 4) {
        int m = atoi(argv[1]), r = atoi(argv[2]), b = atoi(argv[3]);
        int iters = argc >= 5 ? atoi(argv[4]) : 20;
        printf("== interleaved additive-NTT (karatsuba+clmad), %d iters ==\n", iters);
        run_one(m, r, b, iters);
        return 0;
    }

    printf("== interleaved additive-NTT (karatsuba+clmad, fused 4/2/1 layers), rate 1/2, batch 5 ==\n");
    for (int m = 20; m <= 31; m += (m < 26 ? 2 : 1)) {
        int iters = m >= 28 ? 5 : 20;
        run_one(m, 1, 5, iters);
    }
    return 0;
}
