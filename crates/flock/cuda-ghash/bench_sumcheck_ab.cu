// Throughput baseline for the a·b multilinear sumcheck (GPU pcs::open /
// Ligerito. No oracle. Correctness is validated by
// test_sumcheck_ab; here we only time. a,b are generated on-device.
//
// What's timed: the full L-round sumcheck cascade the CPU prover runs over the
// message-length vectors — per round a reduce-per-term message reduction
// ({u_0,u_2}) plus an adjacent-pair fold of a,b, halving each round. Challenges
// are precomputed (the real prover derives them host-side from each message via
// Fiat-Shamir — a small serial cost layered on top, not timed here).
//
// Size: a,b have length 2^L with L = log_msg_len = m - LOG_PACKING(7), matching
// bench_commit_ntt so m lines up across benches.
//
// Per round: message = 2 muls/pair; fold = 2 full muls/pair.
//
// Build:  make bench_sumcheck_ab
// Run:    ./bench_sumcheck_ab 33 [iters]   (default sweep if no args)
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include "sumcheck_ab.cuh"

#define CK(x) do { cudaError_t e=(x); if(e){ \
    printf("CUDA error %s at %s:%d\n", cudaGetErrorString(e), __FILE__, __LINE__); \
    exit(1);} } while(0)

__global__ void fill_sumcheck_inputs(F128* A, F128* B, long long n) {
    long long i = blockIdx.x * (long long)blockDim.x + threadIdx.x;
    if (i >= n) return;
    u64 x = (u64)i * 0x9E3779B97F4A7C15ull + 1;
    u64 y = x * 0xBF58476D1CE4E5B9ull;
    A[i] = F128{x, y};
    B[i] = F128{y ^ 0x123, x ^ 0x456};
}

static void run_one(int m, int iters) {
    const int LOG_PACKING = 7;
    int L = m - LOG_PACKING;                 // log_msg_len; a,b length = 2^L
    long long init_len = 1LL << L;

    double gib = init_len * 16.0 / (1024.0 * 1024.0 * 1024.0);

    F128 *dA, *dB, *dAn, *dBn, *d_u0, *d_u2;
    F128 *d_p0, *d_p2;
    CK(cudaMalloc(&dA, init_len * sizeof(F128)));
    CK(cudaMalloc(&dB, init_len * sizeof(F128)));
    CK(cudaMalloc(&dAn, init_len * sizeof(F128)));
    CK(cudaMalloc(&dBn, init_len * sizeof(F128)));
    CK(cudaMalloc(&d_p0, SMC_MAX_BLOCKS * sizeof(F128)));
    CK(cudaMalloc(&d_p2, SMC_MAX_BLOCKS * sizeof(F128)));
    CK(cudaMalloc(&d_u0, sizeof(F128)));
    CK(cudaMalloc(&d_u2, sizeof(F128)));

    // Precomputed per-round challenges (values irrelevant for timing).
    std::vector<F128> chal(L);
    u64 s = 0xC0FFEEull;
    for (int k = 0; k < L; k++) {
        s += 0x9E3779B97F4A7C15ull;
        u64 z = s;
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
        chal[k] = F128{z ^ (z >> 31), z * 0x2545F4914F6CDD1Dull};
    }

    int tpb = 256;
    long long fb = (init_len + tpb - 1) / tpb;
    fill_sumcheck_inputs<<<(unsigned)fb, tpb>>>(dA, dB, init_len);
    CK(cudaGetLastError());

    auto run_cascade = [&]() {
        F128 *cA = dA, *cB = dB, *nA = dAn, *nB = dBn;
        long long len = init_len;
        for (int k = 0; k < L; k++) {
            long long half = len / 2;
            launch_sumcheck_message(cA, cB, half, d_p0, d_p2, d_u0, d_u2);
            launch_sumcheck_fold(cA, cB, nA, nB, half, chal[k]);
            F128* t;
            t = cA; cA = nA; nA = t;
            t = cB; cB = nB; nB = t;
            len = half;
        }
    };

    run_cascade();                  // warm-up
    CK(cudaDeviceSynchronize());

    cudaEvent_t a, b; CK(cudaEventCreate(&a)); CK(cudaEventCreate(&b));
    CK(cudaEventRecord(a));
    for (int it = 0; it < iters; it++) run_cascade();
    CK(cudaEventRecord(b));
    CK(cudaEventSynchronize(b));
    float ms_total = 0; CK(cudaEventElapsedTime(&ms_total, a, b));
    double ms = ms_total / iters;

    double muls = 0.0, bytes = 0.0;
    long long len = init_len;
    for (int k = 0; k < L; k++) {
        long long half = len / 2;
        muls  += 4.0 * (double)half;                 // 2 msg + 2 fold muls/pair
        bytes += 5.0 * (double)len * 16.0;           // msg read 2·len, fold read 2·len + write len
        len = half;
    }
    double gmuls = muls / (ms * 1e-3) / 1e9;
    double gbps  = bytes / (ms * 1e-3) / 1e9;

    printf("  m=%-2d L=%-2d | a,b len=2^%d buf=%6.3f GiB (×4) | rounds=%2d | "
           "%8.3f ms  %7.2f GMul/s  %7.1f GB/s\n",
           m, L, L, gib, L, ms, gmuls, gbps);

    CK(cudaEventDestroy(a)); CK(cudaEventDestroy(b));
    cudaFree(dA); cudaFree(dB); cudaFree(dAn); cudaFree(dBn);
    cudaFree(d_p0); cudaFree(d_p2); cudaFree(d_u0); cudaFree(d_u2);
}

int main(int argc, char** argv) {
    int dev = 0; cudaDeviceProp p; CK(cudaGetDeviceProperties(&p, dev));
    printf("Device: %s | %d SMs | sm_%d%d\n\n", p.name, p.multiProcessorCount, p.major, p.minor);

    if (argc >= 2) {
        int m = atoi(argv[1]);
        int iters = argc >= 3 ? atoi(argv[2]) : 20;
        printf("== a·b sumcheck cascade (reduce-per-term msg + fold), %d iters ==\n", iters);
        run_one(m, iters);
        return 0;
    }

    printf("== a·b sumcheck cascade (reduce-per-term msg + fold), default sweep ==\n");
    for (int m = 20; m <= 31; m += (m < 26 ? 2 : 1)) {
        int iters = m >= 28 ? 10 : 20;
        run_one(m, iters);
    }
    return 0;
}
