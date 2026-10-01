// Throughput for the BLAKE3 witness-gen kernels (S4 GPU target). No oracle —
// correctness is validated by test_blake3_witness; here we only time, with
// random Compression inputs generated on-device. Compare to the CPU
// genwitness_phase bench (~5.2 ms @ m=29 / 32768 blocks).
//
// Build:  make bench_blake3_witness
// Run:    ./bench_blake3_witness            (default sweep)
//         ./bench_blake3_witness 15 30      (n_blocks_log iters)
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include "blake3_witness.cuh"

#define CK(x) do { cudaError_t e=(x); if(e){ printf("CUDA err %s @%d\n", cudaGetErrorString(e), __LINE__); exit(1);} } while(0)

// Fill the SoA Compression inputs with deterministic pseudo-random values.
__global__ void fill_inputs(uint32_t* cv, uint32_t* m, b3u64* ctr, uint32_t* blen,
                            uint32_t* flags, int n_blocks) {
    int blk = blockIdx.x * blockDim.x + threadIdx.x;
    if (blk >= n_blocks) return;
    b3u64 s = (b3u64)blk * 0x9E3779B97F4A7C15ull + 1;
#define NXT (s = s * 6364136223846793005ull + 1, (uint32_t)(s >> 33))
    for (int w = 0; w < 8; w++) cv[blk * 8 + w] = NXT;
    for (int i = 0; i < 16; i++) m[blk * 16 + i] = NXT;
    ctr[blk] = ((b3u64)NXT << 32) | NXT;
    blen[blk] = NXT;
    flags[blk] = NXT;
#undef NXT
}

static float ev_ms(cudaEvent_t a, cudaEvent_t b) { float ms = 0; cudaEventElapsedTime(&ms, a, b); return ms; }

static void run_one(int n_blocks_log, int iters) {
    long long n_total = 1LL << n_blocks_log;
    int n_blocks = (int)n_total;                       // fully populated
    long long u64_total = n_total * B3_U64_PER_BLOCK;
    long long lincheck_bytes = (n_total / 8) * (long long)B3_K;
    int m = B3_K_LOG + n_blocks_log;

    uint32_t *d_cv, *d_m, *d_blen, *d_flags;
    b3u64 *d_ctr, *d_z, *d_a, *d_b;
    uint8_t* d_lin;
    CK(cudaMalloc(&d_cv, (size_t)n_blocks * 8 * 4));
    CK(cudaMalloc(&d_m, (size_t)n_blocks * 16 * 4));
    CK(cudaMalloc(&d_blen, (size_t)n_blocks * 4));
    CK(cudaMalloc(&d_flags, (size_t)n_blocks * 4));
    CK(cudaMalloc(&d_ctr, (size_t)n_blocks * 8));
    CK(cudaMalloc(&d_z, u64_total * 8));
    CK(cudaMalloc(&d_a, u64_total * 8));
    CK(cudaMalloc(&d_b, u64_total * 8));
    CK(cudaMalloc(&d_lin, lincheck_bytes));
    fill_inputs<<<(unsigned)((n_blocks + 127) / 128), 128>>>(d_cv, d_m, d_ctr, d_blen, d_flags, n_blocks);
    CK(cudaDeviceSynchronize());

    cudaEvent_t e0, e1, e2;
    cudaEventCreate(&e0); cudaEventCreate(&e1); cudaEventCreate(&e2);
    float t_blocks = 0, t_trans = 0;
    for (int it = 0; it < iters; it++) {
        // Fully populated (n_blocks == n_total): every block overwrites all 256
        // words, so no pre-zero needed. (Padded runs would memset for padding.)
        cudaEventRecord(e0);
        launch_blake3_witness_blocks(d_cv, d_m, d_ctr, d_blen, d_flags, n_blocks, n_total, d_z, d_a, d_b);
        cudaEventRecord(e1);
        launch_blake3_lincheck_transpose(d_z, n_total, d_lin);
        cudaEventRecord(e2);
        cudaEventSynchronize(e2);
        t_blocks += ev_ms(e0, e1);
        t_trans += ev_ms(e1, e2);
    }
    t_blocks /= iters; t_trans /= iters;
    double total = t_blocks + t_trans;
    double cps = n_blocks / (total / 1e3);
    double zab_gib = 3.0 * u64_total * 8 / (1024.0 * 1024.0 * 1024.0);
    printf("m=%2d n_blocks=%8d | witness(z/a/b+memset) %7.3f ms  transpose %7.3f ms | "
           "total %7.3f ms  %6.1f Mcompr/s  (z/a/b=%.2f GiB)\n",
           m, n_blocks, t_blocks, t_trans, total, cps / 1e6, zab_gib);

    cudaEventDestroy(e0); cudaEventDestroy(e1); cudaEventDestroy(e2);
    cudaFree(d_cv); cudaFree(d_m); cudaFree(d_blen); cudaFree(d_flags); cudaFree(d_ctr);
    cudaFree(d_z); cudaFree(d_a); cudaFree(d_b); cudaFree(d_lin);
}

int main(int argc, char** argv) {
    if (argc >= 2) {
        int nbl = atoi(argv[1]);
        int iters = argc > 2 ? atoi(argv[2]) : 30;
        run_one(nbl, iters);
        return 0;
    }
    printf("BLAKE3 witness-gen throughput (RTX 5090, sm_120)\n");
    for (int nbl = 13; nbl <= 16; nbl++) run_one(nbl, 30);   // m = 27..30
    return 0;
}
