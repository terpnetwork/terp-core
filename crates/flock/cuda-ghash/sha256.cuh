// Device SHA-256 for the PCS-commit Merkle tree.
//
// Standard FIPS-180-4 SHA-256, big-endian, byte-identical to the `sha2` crate
// used by src/merkle.rs (no domain separation: a leaf is SHA256 of its raw
// bytes, a node is SHA256 of left||right). Correctness-first scalar core; the
// Merkle kernels (merkle.cuh) call sha256() once per leaf / node.
//
// This is the plain software SHA — sm_120 has no SHA hardware instruction
// (unlike the ARM crypto-extension path the CPU uses), so the win is purely
// from running thousands of independent hashes in parallel.
#pragma once
#include <cstdint>

__device__ __constant__ uint32_t SHA256_K[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u, 0x3956c25bu, 0x59f111f1u, 0x923f82a4u,
    0xab1c5ed5u, 0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u, 0x72be5d74u, 0x80deb1feu,
    0x9bdc06a7u, 0xc19bf174u, 0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu, 0x2de92c6fu,
    0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau, 0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u,
    0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u, 0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu,
    0x53380d13u, 0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u, 0xa2bfe8a1u, 0xa81a664bu,
    0xc24b8b70u, 0xc76c51a3u, 0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u, 0x19a4c116u,
    0x1e376c08u, 0x2748774cu, 0x34b0bcb5u, 0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
    0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u, 0x90befffau, 0xa4506cebu, 0xbef9a3f7u,
    0xc67178f2u};

__device__ __forceinline__ uint32_t rotr32(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }

// Compress one 64-byte big-endian block into state h[0..8].
__device__ __forceinline__ void sha256_compress(uint32_t h[8], const uint8_t* p) {
    uint32_t w[64];
#pragma unroll
    for (int i = 0; i < 16; i++) {
        w[i] = ((uint32_t)p[4 * i] << 24) | ((uint32_t)p[4 * i + 1] << 16) |
               ((uint32_t)p[4 * i + 2] << 8) | ((uint32_t)p[4 * i + 3]);
    }
#pragma unroll
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = rotr32(w[i - 15], 7) ^ rotr32(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = rotr32(w[i - 2], 17) ^ rotr32(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
#pragma unroll
    for (int i = 0; i < 64; i++) {
        uint32_t S1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25);
        uint32_t ch = (e & f) ^ (~e & g);
        uint32_t t1 = hh + S1 + ch + SHA256_K[i] + w[i];
        uint32_t S0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22);
        uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
        uint32_t t2 = S0 + maj;
        hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}

// SHA-256 of `len` bytes at `msg`, writing the 32-byte big-endian digest to out.
__device__ __forceinline__ void sha256(const uint8_t* msg, uint32_t len, uint8_t* out) {
    uint32_t h[8] = {0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
                     0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u};
    uint32_t i = 0;
    for (; i + 64 <= len; i += 64) sha256_compress(h, msg + i);

    // Tail: remaining bytes + 0x80 + zero pad + 64-bit big-endian bit length.
    uint8_t block[64];
    uint32_t rem = len - i;
    for (uint32_t j = 0; j < rem; j++) block[j] = msg[i + j];
    block[rem] = 0x80;
    uint64_t bitlen = (uint64_t)len * 8;
    if (rem < 56) {
        for (uint32_t j = rem + 1; j < 56; j++) block[j] = 0;
#pragma unroll
        for (int j = 0; j < 8; j++) block[56 + j] = (uint8_t)(bitlen >> (56 - 8 * j));
        sha256_compress(h, block);
    } else {
        for (uint32_t j = rem + 1; j < 64; j++) block[j] = 0;
        sha256_compress(h, block);
        for (int j = 0; j < 56; j++) block[j] = 0;
#pragma unroll
        for (int j = 0; j < 8; j++) block[56 + j] = (uint8_t)(bitlen >> (56 - 8 * j));
        sha256_compress(h, block);
    }

#pragma unroll
    for (int i2 = 0; i2 < 8; i2++) {
        out[4 * i2]     = (uint8_t)(h[i2] >> 24);
        out[4 * i2 + 1] = (uint8_t)(h[i2] >> 16);
        out[4 * i2 + 2] = (uint8_t)(h[i2] >> 8);
        out[4 * i2 + 3] = (uint8_t)(h[i2]);
    }
}

// Compress one block given as 16 already-big-endian u32 words (clobbers w).
// Sliding 16-word schedule — 16 registers instead of sha256_compress's w[64].
__device__ __forceinline__ void sha256_compress_words(uint32_t h[8], uint32_t w[16]) {
    uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
#pragma unroll
    for (int i = 0; i < 64; i++) {
        uint32_t wi;
        if (i < 16) {
            wi = w[i];
        } else {
            uint32_t w1  = w[(i + 1) & 15];
            uint32_t w14 = w[(i + 14) & 15];
            uint32_t s0 = rotr32(w1, 7) ^ rotr32(w1, 18) ^ (w1 >> 3);
            uint32_t s1 = rotr32(w14, 17) ^ rotr32(w14, 19) ^ (w14 >> 10);
            w[i & 15] = w[i & 15] + s0 + w[(i + 9) & 15] + s1;
            wi = w[i & 15];
        }
        uint32_t S1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25);
        uint32_t ch = (e & f) ^ (~e & g);
        uint32_t t1 = hh + S1 + ch + SHA256_K[i] + wi;
        uint32_t S0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22);
        uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
        hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + S0 + maj;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}

// ---------------------------------------------------------------------------
// K-way interleaved SHA-256: one thread hashes K independent equal-length
// inputs, running the K compression chains together for ILP. Mirrors the CPU's
// 4-way interleave (src/merkle.rs::compress4).
//
// MEASURED REGRESSION ON GPU — kept default-off (launch_merkle kway=1). On the
// 5090 it's monotonically SLOWER (m=29: kway1 0.65 / kway2 0.78 / kway4 0.90
// ms): with hundreds of thousands of independent leaves the one-thread-per-leaf
// kernel (56 regs) already hides SHA's serial chain via thread-level
// parallelism and is throughput-bound, so adding per-thread ILP just inflates
// registers (kway2 212, kway4 255+spills) and tanks occupancy. The CPU needs
// 4-way ILP because it has few cores; the GPU does not. Kept as a documented
// negative result. Digests are bit-identical to sha256().
// ---------------------------------------------------------------------------

// Compress one block per stream. st[k] is stream k's state; w[k] its 16 loaded
// big-endian words (mutated in place as the sliding schedule advances).
template <int K>
__device__ __forceinline__ void sha256_compress_kway(uint32_t st[K][8], uint32_t w[K][16]) {
    uint32_t a[K], b[K], c[K], d[K], e[K], f[K], g[K], hh[K];
#pragma unroll
    for (int k = 0; k < K; k++) {
        a[k] = st[k][0]; b[k] = st[k][1]; c[k] = st[k][2]; d[k] = st[k][3];
        e[k] = st[k][4]; f[k] = st[k][5]; g[k] = st[k][6]; hh[k] = st[k][7];
    }
#pragma unroll
    for (int i = 0; i < 64; i++) {
#pragma unroll
        for (int k = 0; k < K; k++) {
            uint32_t wi;
            if (i < 16) {
                wi = w[k][i];
            } else {
                uint32_t w1  = w[k][(i + 1) & 15];
                uint32_t w14 = w[k][(i + 14) & 15];
                uint32_t s0 = rotr32(w1, 7) ^ rotr32(w1, 18) ^ (w1 >> 3);
                uint32_t s1 = rotr32(w14, 17) ^ rotr32(w14, 19) ^ (w14 >> 10);
                w[k][i & 15] = w[k][i & 15] + s0 + w[k][(i + 9) & 15] + s1;
                wi = w[k][i & 15];
            }
            uint32_t S1 = rotr32(e[k], 6) ^ rotr32(e[k], 11) ^ rotr32(e[k], 25);
            uint32_t ch = (e[k] & f[k]) ^ (~e[k] & g[k]);
            uint32_t t1 = hh[k] + S1 + ch + SHA256_K[i] + wi;
            uint32_t S0 = rotr32(a[k], 2) ^ rotr32(a[k], 13) ^ rotr32(a[k], 22);
            uint32_t maj = (a[k] & b[k]) ^ (a[k] & c[k]) ^ (b[k] & c[k]);
            uint32_t t2 = S0 + maj;
            hh[k] = g[k]; g[k] = f[k]; f[k] = e[k]; e[k] = d[k] + t1;
            d[k] = c[k]; c[k] = b[k]; b[k] = a[k]; a[k] = t1 + t2;
        }
    }
#pragma unroll
    for (int k = 0; k < K; k++) {
        st[k][0] += a[k]; st[k][1] += b[k]; st[k][2] += c[k]; st[k][3] += d[k];
        st[k][4] += e[k]; st[k][5] += f[k]; st[k][6] += g[k]; st[k][7] += hh[k];
    }
}

__device__ __forceinline__ uint32_t load_be32(const uint8_t* p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

// Hash K equal-length inputs: stream k starts at base + k*in_stride, `len`
// bytes; digest written to obase + k*out_stride. (For Merkle leaves
// in_stride = leaf_size; for the level kernel in_stride = 64.)
template <int K>
__device__ __forceinline__ void sha256_kway(const uint8_t* base, long long in_stride,
                                            uint32_t len, uint8_t* obase, long long out_stride) {
    uint32_t st[K][8];
#pragma unroll
    for (int k = 0; k < K; k++) {
        st[k][0] = 0x6a09e667u; st[k][1] = 0xbb67ae85u; st[k][2] = 0x3c6ef372u; st[k][3] = 0xa54ff53au;
        st[k][4] = 0x510e527fu; st[k][5] = 0x9b05688cu; st[k][6] = 0x1f83d9abu; st[k][7] = 0x5be0cd19u;
    }
    uint32_t w[K][16];
    uint32_t off = 0;
    for (; off + 64 <= len; off += 64) {
#pragma unroll
        for (int k = 0; k < K; k++) {
            const uint8_t* p = base + (long long)k * in_stride + off;
#pragma unroll
            for (int j = 0; j < 16; j++) w[k][j] = load_be32(p + 4 * j);
        }
        sha256_compress_kway<K>(st, w);
    }

    // Tail block(s): remaining bytes + 0x80 + zero pad + 64-bit BE length.
    uint32_t rem = len - off;
    int ntail = (rem < 56) ? 1 : 2;
    uint64_t bitlen = (uint64_t)len * 8;
    uint8_t blk[K][128];
#pragma unroll
    for (int k = 0; k < K; k++) {
        for (int j = 0; j < ntail * 64; j++) blk[k][j] = 0;
        const uint8_t* p = base + (long long)k * in_stride + off;
        for (uint32_t j = 0; j < rem; j++) blk[k][j] = p[j];
        blk[k][rem] = 0x80;
#pragma unroll
        for (int j = 0; j < 8; j++) blk[k][ntail * 64 - 8 + j] = (uint8_t)(bitlen >> (56 - 8 * j));
    }
    for (int t = 0; t < ntail; t++) {
#pragma unroll
        for (int k = 0; k < K; k++)
#pragma unroll
            for (int j = 0; j < 16; j++) w[k][j] = load_be32(blk[k] + t * 64 + 4 * j);
        sha256_compress_kway<K>(st, w);
    }

#pragma unroll
    for (int k = 0; k < K; k++) {
        uint8_t* o = obase + (long long)k * out_stride;
#pragma unroll
        for (int i2 = 0; i2 < 8; i2++) {
            o[4 * i2]     = (uint8_t)(st[k][i2] >> 24);
            o[4 * i2 + 1] = (uint8_t)(st[k][i2] >> 16);
            o[4 * i2 + 2] = (uint8_t)(st[k][i2] >> 8);
            o[4 * i2 + 3] = (uint8_t)(st[k][i2]);
        }
    }
}
