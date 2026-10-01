// Device-resident Merkle multi-proof — perf path for the Ligerito query opening.
// Instead of copying the whole tree to host (64MB at log_n=24), compute the
// emitted node-index list on host (positions-only, cheap) and gather just those
// ~q·d sibling hashes from the device tree (~tens of KB). Byte-identical to
// merkle_multi_proof_host.
#pragma once
#include <cstdio>
#include <cstdlib>
#include <vector>
#include "merkle_open.hpp"   // MHash, merkle_multi_proof_indices

// Fail fast on any CUDA error, like the .cu translation units' CK macros.
// A swallowed error here would return success with a zeroed opening path —
// the prover must die loudly instead.
#define MOD_CK(x)                                                              \
    do {                                                                       \
        cudaError_t mod_e_ = (x);                                              \
        if (mod_e_) {                                                          \
            fprintf(stderr, "CUDA err %s @%s:%d\n",                           \
                    cudaGetErrorString(mod_e_), __FILE__, __LINE__);           \
            exit(1);                                                           \
        }                                                                      \
    } while (0)

__global__ void gather_tree_nodes(const uint8_t* __restrict__ tree,
                                  const unsigned long long* __restrict__ idxs,
                                  int n, uint8_t* __restrict__ out) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const uint8_t* src = tree + idxs[i] * 32;
    uint8_t* dst = out + (size_t)i * 32;
    #pragma unroll
    for (int j = 0; j < 32; j++) dst[j] = src[j];
}

// Gather an arbitrary host-computed node-index list from a device tree.
inline std::vector<MHash> gather_tree_nodes_device(const uint8_t* d_tree,
                                                   const std::vector<size_t>& idxs) {
    int n = (int)idxs.size();
    std::vector<MHash> out(n);
    if (n == 0) return out;
    unsigned long long* d_idx = nullptr;
    uint8_t* d_out = nullptr;
    std::vector<unsigned long long> h_idx(idxs.begin(), idxs.end());
    MOD_CK(cudaMalloc(&d_idx, (size_t)n * sizeof(unsigned long long)));
    MOD_CK(cudaMalloc(&d_out, (size_t)n * 32));
    MOD_CK(cudaMemcpy(d_idx, h_idx.data(), (size_t)n * sizeof(unsigned long long), cudaMemcpyHostToDevice));
    int tpb = 128;
    gather_tree_nodes<<<(n + tpb - 1) / tpb, tpb>>>(d_tree, d_idx, n, d_out);
    MOD_CK(cudaGetLastError());
    MOD_CK(cudaMemcpy(out.data(), d_out, (size_t)n * 32, cudaMemcpyDeviceToHost));
    MOD_CK(cudaFree(d_idx));
    MOD_CK(cudaFree(d_out));
    return out;
}

// Capped per-query paths against a device-resident tree (the live protocol).
inline std::vector<MHash> merkle_capped_paths_device(const uint8_t* d_tree, size_t num_leaves,
                                                     const std::vector<size_t>& queries,
                                                     uint32_t cap_depth) {
    return gather_tree_nodes_device(d_tree, merkle_capped_path_indices(num_leaves, queries, cap_depth));
}

// The absorbed commitment: the 2^c cap-layer nodes (contiguous slice of the
// flat tree — src/merkle.rs::cap_layer: the level with L nodes starts at
// 2N − 2L).
inline std::vector<MHash> merkle_cap_layer_device(const uint8_t* d_tree, size_t num_leaves,
                                                  uint32_t cap_depth) {
    size_t l = (size_t)1 << cap_depth;
    std::vector<MHash> cap(l);
    MOD_CK(cudaMemcpy(cap.data(), d_tree + (2 * num_leaves - 2 * l) * 32, l * 32,
                     cudaMemcpyDeviceToHost));
    return cap;
}

// Multi-proof over a device-resident tree `d_tree`. No full-tree D2H.
inline std::vector<MHash> merkle_multi_proof_device(const uint8_t* d_tree, size_t num_leaves,
                                                    const std::vector<size_t>& positions) {
    std::vector<size_t> idxs = merkle_multi_proof_indices(num_leaves, positions);
    int n = (int)idxs.size();
    std::vector<MHash> out(n);
    if (n == 0) return out;
    // Pooled (grow-only) device scratch + pinned host staging — the per-call
    // cudaMalloc/cudaFree was the whole cost of this tiny gather. Pinned H/D
    // staging makes the two small copies fast.
    static unsigned long long* d_idx = nullptr;
    static uint8_t* d_out = nullptr;
    static unsigned long long* h_idx = nullptr;   // pinned
    static uint8_t* h_out = nullptr;               // pinned
    static int cap = 0;
    if (n > cap) {
        if (d_idx) { cudaFree(d_idx); cudaFree(d_out); cudaFreeHost(h_idx); cudaFreeHost(h_out); }
        cap = n + (n >> 1);  // headroom to avoid frequent regrow
        MOD_CK(cudaMalloc(&d_idx, (size_t)cap * sizeof(unsigned long long)));
        MOD_CK(cudaMalloc(&d_out, (size_t)cap * 32));
        MOD_CK(cudaHostAlloc(&h_idx, (size_t)cap * sizeof(unsigned long long), cudaHostAllocDefault));
        MOD_CK(cudaHostAlloc(&h_out, (size_t)cap * 32, cudaHostAllocDefault));
    }
    for (int i = 0; i < n; i++) h_idx[i] = (unsigned long long)idxs[i];
    MOD_CK(cudaMemcpy(d_idx, h_idx, (size_t)n * sizeof(unsigned long long), cudaMemcpyHostToDevice));
    int tpb = 128;
    gather_tree_nodes<<<(n + tpb - 1) / tpb, tpb>>>(d_tree, d_idx, n, d_out);
    MOD_CK(cudaGetLastError());
    MOD_CK(cudaMemcpy(h_out, d_out, (size_t)n * 32, cudaMemcpyDeviceToHost));
    memcpy(out.data(), h_out, (size_t)n * 32);
    return out;
}
