// Throughput baseline for the P3 Merkle (SHA-256) kernels. Leaves are generated
// on-device (no oracle), so it scales to realistic m. Params follow the commit
// (LOG_PACKING=7, rate 1/2, batch 5): n_leaves = 2^k_code, leaf = num_ntts*16.
//
// Build:  make bench_merkle
// Run:    ./bench_merkle [m log_inv_rate log_batch_size [iters]]
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include "merkle.cuh"

#define CK(x) do { cudaError_t e=(x); if(e){ \
    printf("CUDA error %s at %s:%d\n", cudaGetErrorString(e), __FILE__, __LINE__); \
    exit(1);} } while(0)

__global__ void fill_benchmark_input(uint8_t* d, long long n) {
    long long i = blockIdx.x * (long long)blockDim.x + threadIdx.x;
    if (i >= n) return;
    d[i] = (uint8_t)(i * 1315423911ull >> 13);
}

static void run_one(int m, int log_inv_rate, int log_batch_size, int iters, int kway) {
    const int LOG_PACKING = 7;
    int log_msg_len = m - LOG_PACKING;
    int k_code      = (log_msg_len - log_batch_size) + log_inv_rate;
    int num_ntts    = 1 << log_batch_size;
    long long n_leaves   = 1LL << k_code;
    int leaf_size        = num_ntts * 16;
    long long data_bytes = n_leaves * leaf_size;
    long long total_nodes = 2 * n_leaves - 1;
    double gib = data_bytes / (1024.0 * 1024.0 * 1024.0);

    uint8_t *d_data = nullptr, *d_tree = nullptr;
    CK(cudaMalloc(&d_data, data_bytes));
    CK(cudaMalloc(&d_tree, total_nodes * 32));
    long long fb = (data_bytes + 255) / 256;
    fill_benchmark_input<<<(unsigned)fb, 256>>>(d_data, data_bytes);
    CK(cudaGetLastError());

    launch_merkle(d_data, d_tree, n_leaves, leaf_size, 256, kway);      // warm-up
    CK(cudaDeviceSynchronize());

    cudaEvent_t a, b; CK(cudaEventCreate(&a)); CK(cudaEventCreate(&b));
    CK(cudaEventRecord(a));
    for (int it = 0; it < iters; it++) launch_merkle(d_data, d_tree, n_leaves, leaf_size, 256, kway);
    CK(cudaEventRecord(b));
    CK(cudaEventSynchronize(b));
    float ms_total = 0; CK(cudaEventElapsedTime(&ms_total, a, b));
    double ms = ms_total / iters;

    // SHA-256 compressions: leaves = n_leaves * (leaf_size/64 + 1); nodes ~ 2 each.
    double leaf_compr = (double)n_leaves * (leaf_size / 64 + 1);
    double node_compr = (double)(n_leaves - 1) * 2.0;
    double gcompr = (leaf_compr + node_compr) / (ms * 1e-3) / 1e9;
    double gbps = data_bytes / (ms * 1e-3) / 1e9;

    printf("  m=%-2d kway=%d | k_code=%2d leaves=%9lld leaf=%4dB data=%6.3f GiB | "
           "%8.3f ms  %6.2f Gcompr/s  %7.1f GB/s\n",
           m, kway, k_code, n_leaves, leaf_size, gib, ms, gcompr, gbps);

    CK(cudaEventDestroy(a)); CK(cudaEventDestroy(b));
    cudaFree(d_data); cudaFree(d_tree);
}

int main(int argc, char** argv) {
    int dev = 0; cudaDeviceProp p; CK(cudaGetDeviceProperties(&p, dev));
    printf("Device: %s | %d SMs | sm_%d%d\n\n", p.name, p.multiProcessorCount, p.major, p.minor);

    if (argc >= 4) {
        int iters = argc >= 5 ? atoi(argv[4]) : 20;
        int kway = argc >= 6 ? atoi(argv[5]) : 1;
        printf("== Merkle SHA-256, %d iters ==\n", iters);
        run_one(atoi(argv[1]), atoi(argv[2]), atoi(argv[3]), iters, kway);
        return 0;
    }
    printf("== Merkle SHA-256, rate 1/2, batch 5 — kway sweep ==\n");
    for (int m = 27; m <= 30; m++) {
        int iters = m >= 28 ? 5 : 20;
        for (int kway : {1, 2, 4}) run_one(m, 1, 5, iters, kway);
    }
    return 0;
}
