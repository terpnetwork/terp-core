// GPU Merkle tree (SHA-256) for the PCS commit.
//
// Mirrors src/merkle.rs::merkle_tree exactly:
//   * flat layout: tree[0..n] = leaf hashes, then each level above, root last;
//     total 2n-1 nodes.
//   * leaf i = SHA256(codeword bytes [i*leaf_size, (i+1)*leaf_size)) where
//     leaf_size = num_ntts*16 (one codeword position's lanes, no domain sep).
//   * parent = SHA256(left || right), 64-byte preimage.
//
// Leaf hashing dominates (each leaf is leaf_size/64 + 1 compressions vs 2 per
// node), and all leaves / all nodes within a level are independent — one thread
// per leaf, one thread per node, one kernel launch per level (levels are
// sequential, ordered by the stream).
#pragma once
#include <cstdint>
#include "sha256.cuh"

typedef uint8_t Hash[32];

// One thread per leaf: hash leaf_size contiguous bytes into tree[leaf].
__global__ void hash_merkle_leaves(const uint8_t* data, uint8_t* tree,
                                   long long num_leaves, int leaf_size) {
    long long i = blockIdx.x * (long long)blockDim.x + threadIdx.x;
    if (i >= num_leaves) return;
    sha256(data + i * (long long)leaf_size, (uint32_t)leaf_size, tree + i * 32);
}

// K leaves per thread, interleaved (ILP-hidden SHA dependency chain).
template <int K>
__global__ void hash_merkle_leaves_in_parallel(const uint8_t* data, uint8_t* tree,
                                        long long num_leaves, int leaf_size) {
    long long grp = blockIdx.x * (long long)blockDim.x + threadIdx.x;
    long long first = grp * K;
    if (first >= num_leaves) return;
    if (first + K <= num_leaves) {
        sha256_kway<K>(data + first * (long long)leaf_size, leaf_size, (uint32_t)leaf_size,
                       tree + first * 32, 32);
    } else {
        for (long long i = first; i < num_leaves; i++)
            sha256(data + i * (long long)leaf_size, (uint32_t)leaf_size, tree + i * 32);
    }
}

// Warp-staged leaf hashing (leaf_size % 128 == 0). The naive kernels above are
// L1-pipe-bound, not SHA-bound (measured 85% L1/TEX vs 26% SM at m=33): each
// thread walks its own leaf with byte loads, so every load is a separate
// uncoalesced sector. Here a warp owns 32 consecutive leaves and alternates:
//   stage  — the warp loads a 128-byte chunk of each of its 32 leaves as
//            uint4s (8 per chunk; lanes cover 4 chunks per iteration, fully
//            coalesced within each 128 B segment) into shared memory, padded
//            to a 33-word leaf stride so bank(l,w) = (l+w)%32 — conflict-free
//            both on the strided store and on the per-lane hash reads;
//   hash   — lane l compresses the two 64-byte blocks of ITS leaf's chunk
//            straight from shared (BE byte-swap on the register read).
// The trailing padding block (0x80 ... bitlen) is a constant — computed in
// registers, no staging. Digest layout matches sha256() bit-for-bit.
__global__ void hash_staged_merkle_leaves(const uint8_t* __restrict__ data, uint8_t* tree,
                                          long long num_leaves, int leaf_size) {
    extern __shared__ uint32_t sw[];                  // 32*33 words per warp
    int wid = threadIdx.x >> 5, lane = threadIdx.x & 31;
    uint32_t* s = sw + wid * (32 * 33);
    long long warp0 = ((long long)blockIdx.x * (blockDim.x >> 5) + wid) * 32;
    if (warp0 >= num_leaves) return;
    long long myleaf = warp0 + lane;

    uint32_t h[8] = {0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
                     0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u};
    int nchunks = leaf_size >> 7;
    for (int c = 0; c < nchunks; c++) {
#pragma unroll
        for (int it = 0; it < 8; it++) {
            int idx   = it * 32 + lane;               // 0..255: uint4s of this stage
            int piece = idx >> 3, off = idx & 7;      // leaf-chunk, uint4 within it
            long long leaf = warp0 + piece;
            uint4 v = make_uint4(0, 0, 0, 0);
            if (leaf < num_leaves)
                v = *(const uint4*)(data + leaf * (long long)leaf_size + (long long)c * 128 + off * 16);
            uint32_t* d = s + piece * 33 + off * 4;
            d[0] = v.x; d[1] = v.y; d[2] = v.z; d[3] = v.w;
        }
        __syncwarp();
        if (myleaf < num_leaves) {
#pragma unroll
            for (int b = 0; b < 2; b++) {
                uint32_t w[16];
#pragma unroll
                for (int j = 0; j < 16; j++)
                    w[j] = __byte_perm(s[lane * 33 + b * 16 + j], 0, 0x0123);
                sha256_compress_words(h, w);
            }
        }
        __syncwarp();
    }
    if (myleaf >= num_leaves) return;

    uint32_t w[16];                                   // constant padding block
    w[0] = 0x80000000u;
#pragma unroll
    for (int j = 1; j < 14; j++) w[j] = 0;
    uint64_t bitlen = (uint64_t)leaf_size * 8;
    w[14] = (uint32_t)(bitlen >> 32); w[15] = (uint32_t)bitlen;
    sha256_compress_words(h, w);

    uint4* o = (uint4*)(tree + myleaf * 32);
    o[0] = make_uint4(__byte_perm(h[0], 0, 0x0123), __byte_perm(h[1], 0, 0x0123),
                      __byte_perm(h[2], 0, 0x0123), __byte_perm(h[3], 0, 0x0123));
    o[1] = make_uint4(__byte_perm(h[4], 0, 0x0123), __byte_perm(h[5], 0, 0x0123),
                      __byte_perm(h[6], 0, 0x0123), __byte_perm(h[7], 0, 0x0123));
}

// One thread per parent: hash the 64-byte child pair into the parent node.
// read_start/write_start are node indices into the flat tree.
__global__ void hash_merkle_level(uint8_t* tree, long long read_start,
                                    long long write_start, long long num_parents) {
    long long j = blockIdx.x * (long long)blockDim.x + threadIdx.x;
    if (j >= num_parents) return;
    const uint8_t* children = tree + (read_start + 2 * j) * 32;   // 2 contiguous 32-byte hashes
    sha256(children, 64, tree + (write_start + j) * 32);
}

// Build the full Merkle tree in d_tree (must hold 2*num_leaves-1 Hash nodes)
// over d_data (num_leaves * leaf_size bytes). Caller syncs; root is the last
// node, d_tree + (2*num_leaves-2)*32.
// `kway` = leaves hashed per thread (1, 2, or 4); interleaves the SHA chains
// for ILP. kway=1 is the simple one-thread-per-leaf path.
inline void launch_merkle(const uint8_t* d_data, uint8_t* d_tree,
                          long long num_leaves, int leaf_size, int tpb = 256, int kway = 1) {
    if (leaf_size % 128 == 0) {                        // warp-staged path (fastest)
        int wpb = tpb >> 5;
        long long warps  = (num_leaves + 31) / 32;
        long long blocks = (warps + wpb - 1) / wpb;
        size_t smem = (size_t)wpb * 32 * 33 * sizeof(uint32_t);
        hash_staged_merkle_leaves<<<(unsigned)blocks, tpb, smem>>>(d_data, d_tree, num_leaves, leaf_size);
    } else if (kway == 2) {
        long long groups = (num_leaves + 1) / 2;
        long long b = (groups + tpb - 1) / tpb;
        hash_merkle_leaves_in_parallel<2><<<(unsigned)b, tpb>>>(d_data, d_tree, num_leaves, leaf_size);
    } else if (kway == 4) {
        long long groups = (num_leaves + 3) / 4;
        long long b = (groups + tpb - 1) / tpb;
        hash_merkle_leaves_in_parallel<4><<<(unsigned)b, tpb>>>(d_data, d_tree, num_leaves, leaf_size);
    } else {
        long long blocks = (num_leaves + tpb - 1) / tpb;
        hash_merkle_leaves<<<(unsigned)blocks, tpb>>>(d_data, d_tree, num_leaves, leaf_size);
    }

    long long read_start = 0, read_len = num_leaves;
    while (read_len > 1) {
        long long next = read_len >> 1;
        long long write_start = read_start + read_len;
        long long b = (next + tpb - 1) / tpb;
        hash_merkle_level<<<(unsigned)b, tpb>>>(d_tree, read_start, write_start, next);
        read_start += read_len;
        read_len = next;
    }
}
