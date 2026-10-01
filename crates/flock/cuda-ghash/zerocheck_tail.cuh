// Zerocheck multilinear sumcheck tail on GPU — port of
// src/zerocheck/multilinear.rs::round_pair_naive (message) + fold_in_place_pair
// (fold). The message is the eq-weighted degree-2 form (adjacent pairing):
//   g_one = Σ_x eq[x]·a[2x+1]·b[2x+1]
//   g_inf = Σ_x eq[x]·(a[2x]+a[2x+1])·(b[2x]+b[2x+1])
//   message = (r[0]·g_one, g_inf)            (r[0]=ONE in zerocheck → msg_1=g_one)
// eq = build_eq(r[1..]). The fold a[x]=a[2x]+ρ·(a[2x+1]+a[2x]) is the same
// adjacent-pair LSB fold as sumcheck_ab.cuh::sumcheck_fold (reused).
#pragma once
#include "f128.cuh"
#include "sumcheck_ab.cuh"   // sumcheck_fold / launch_sumcheck_fold (adjacent LSB fold)

#ifndef ZT_TPB
#define ZT_TPB 256
#endif
#ifndef ZT_MAX_BLOCKS
#define ZT_MAX_BLOCKS 2048
#endif

// Block-partial eq-weighted message reduction (adjacent pairing). Grid-stride.
__global__ void zerocheck_tail_message_partial(const F128* __restrict__ A, const F128* __restrict__ B,
                               const F128* __restrict__ eq, long long half,
                               F128* p1, F128* pinf) {
    __shared__ F128 s1[ZT_TPB];
    __shared__ F128 sinf[ZT_TPB];
    long long t = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    long long stride = (long long)gridDim.x * blockDim.x;
    F128 g1{0, 0}, ginf{0, 0};
    for (long long x = t; x < half; x += stride) {
        F128 a0 = A[2 * x], a1 = A[2 * x + 1];
        F128 b0 = B[2 * x], b1 = B[2 * x + 1];
        F128 e = eq[x];
        g1 = f128_add(g1, ghash_mul_karatsuba(e, ghash_mul_karatsuba(a1, b1)));
        ginf = f128_add(ginf, ghash_mul_karatsuba(e, ghash_mul_karatsuba(
                                  f128_add(a0, a1), f128_add(b0, b1))));
    }
    int x = threadIdx.x;
    s1[x] = g1; sinf[x] = ginf;
    __syncthreads();
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (x < s) { s1[x] = f128_add(s1[x], s1[x + s]); sinf[x] = f128_add(sinf[x], sinf[x + s]); }
        __syncthreads();
    }
    if (x == 0) { p1[blockIdx.x] = s1[0]; pinf[blockIdx.x] = sinf[0]; }
}

// Parallel partials reduction (one 256-thread block). The single-thread loop
// this replaces cost ~200 us at 2048 blocks — same order as the big message
// kernels themselves. XOR-sum order is irrelevant, so this is bit-identical.
__global__ void combine_zerocheck_tail_message(const F128* p1, const F128* pinf, int blocks,
                               F128* m1, F128* minf) {
    __shared__ F128 s1[ZT_TPB];
    __shared__ F128 sinf[ZT_TPB];
    F128 a1{0, 0}, ai{0, 0};
    for (int b = threadIdx.x; b < blocks; b += blockDim.x) { a1 = f128_add(a1, p1[b]); ai = f128_add(ai, pinf[b]); }
    int x = threadIdx.x;
    s1[x] = a1; sinf[x] = ai;
    __syncthreads();
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (x < s) { s1[x] = f128_add(s1[x], s1[x + s]); sinf[x] = f128_add(sinf[x], sinf[x + s]); }
        __syncthreads();
    }
    if (x == 0) { *m1 = s1[0]; *minf = sinf[0]; }
}

// FUSED fold-by-r + next eq-weighted message in ONE pass. Folds A,B (length len) ->
// Ao,Bo (length len/2) by r, and simultaneously computes the next round's message
// (g_one,g_inf) over the folded data weighted by eq (length out_pairs=len/4). Saves a
// whole fold kernel + a data pass per tail round vs separate launch_sumcheck_fold +
// launch_zerocheck_tail_message. Each thread owns one output message-pair x: reads A[4x..4x+3], folds
// to Ao[2x]=af0, Ao[2x+1]=af1, accumulates eq[x]·(af1·bf1) and eq[x]·(af0+af1)(bf0+bf1).
__global__ void zerocheck_tail_fold_and_message_partial(const F128* __restrict__ A, const F128* __restrict__ B,
                                    F128* __restrict__ Ao, F128* __restrict__ Bo,
                                    const F128* __restrict__ eq, long long out_pairs, F128 r,
                                    F128* p1, F128* pinf) {
    __shared__ F128 s1[ZT_TPB];
    __shared__ F128 sinf[ZT_TPB];
    long long t = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    long long stride = (long long)gridDim.x * blockDim.x;
    F128 g1{0, 0}, ginf{0, 0};
    for (long long x = t; x < out_pairs; x += stride) {
        long long i = 4 * x;
        F128 a0 = A[i], a1 = A[i + 1], a2 = A[i + 2], a3 = A[i + 3];
        F128 b0 = B[i], b1 = B[i + 1], b2 = B[i + 2], b3 = B[i + 3];
        F128 af0 = f128_add(a0, ghash_mul_karatsuba(r, f128_add(a0, a1)));   // folded nA[2x]
        F128 af1 = f128_add(a2, ghash_mul_karatsuba(r, f128_add(a2, a3)));   // folded nA[2x+1]
        F128 bf0 = f128_add(b0, ghash_mul_karatsuba(r, f128_add(b0, b1)));
        F128 bf1 = f128_add(b2, ghash_mul_karatsuba(r, f128_add(b2, b3)));
        Ao[2 * x] = af0; Ao[2 * x + 1] = af1; Bo[2 * x] = bf0; Bo[2 * x + 1] = bf1;
        F128 e = eq[x];
        g1 = f128_add(g1, ghash_mul_karatsuba(e, ghash_mul_karatsuba(af1, bf1)));
        ginf = f128_add(ginf, ghash_mul_karatsuba(e, ghash_mul_karatsuba(
                                  f128_add(af0, af1), f128_add(bf0, bf1))));
    }
    int x = threadIdx.x;
    s1[x] = g1; sinf[x] = ginf;
    __syncthreads();
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (x < s) { s1[x] = f128_add(s1[x], s1[x + s]); sinf[x] = f128_add(sinf[x], sinf[x + s]); }
        __syncthreads();
    }
    if (x == 0) { p1[blockIdx.x] = s1[0]; pinf[blockIdx.x] = sinf[0]; }
}

// Incremental eq fold: eq(r[j+1..m])[y] = eq(r[j..m])[2y]·(1+r[j])^{-1}. Halves a length-2n
// eq table to length-n (gather even entries, scale) — replaces a full per-round rebuild in
// the tail (eq tables are nested). inv_scale = (1+r[j])^{-1}, host-precomputed.
__global__ void halve_and_scale_equality_values(const F128* __restrict__ in, F128* __restrict__ out,
                                 long long n, F128 inv_scale) {
    long long y = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    if (y >= n) return;
    out[y] = ghash_mul_karatsuba(in[2 * y], inv_scale);
}
inline void launch_halve_and_scale_equality_values(const F128* d_in, F128* d_out, long long n, F128 inv_scale, int tpb = 256) {
    halve_and_scale_equality_values<<<(unsigned)((n + tpb - 1) / tpb), tpb>>>(d_in, d_out, n, inv_scale);
}

inline int zt_blocks(long long half) {
    long long b = (half + ZT_TPB - 1) / ZT_TPB;
    if (b < 1) b = 1;
    if (b > ZT_MAX_BLOCKS) b = ZT_MAX_BLOCKS;
    return (int)b;
}

// One round's eq-weighted message over (dA,dB) with eq table dEq (length half).
// Leaves (g_one, g_inf) in d_m1/d_minf. r[0]=ONE in zerocheck, so msg_1 = g_one.
inline void launch_zerocheck_tail_message(const F128* dA, const F128* dB, const F128* dEq, long long half,
                          F128* d_p1, F128* d_pinf, F128* d_m1, F128* d_minf) {
    int blocks = zt_blocks(half);
    zerocheck_tail_message_partial<<<blocks, ZT_TPB>>>(dA, dB, dEq, half, d_p1, d_pinf);
    combine_zerocheck_tail_message<<<1, ZT_TPB>>>(d_p1, d_pinf, blocks, d_m1, d_minf);
}

// Fused fold(A,B by r, len -> len/2 into Ao,Bo) + next message over the folded data
// weighted by dEq (length out_pairs = len/4). Leaves (g_one,g_inf) in d_m1/d_minf.
inline void launch_zerocheck_tail_fold_and_message(const F128* dA, const F128* dB, F128* dAo, F128* dBo,
                               const F128* dEq, long long out_pairs, F128 r,
                               F128* d_p1, F128* d_pinf, F128* d_m1, F128* d_minf) {
    int blocks = zt_blocks(out_pairs);
    zerocheck_tail_fold_and_message_partial<<<blocks, ZT_TPB>>>(dA, dB, dAo, dBo, dEq, out_pairs, r, d_p1, d_pinf);
    combine_zerocheck_tail_message<<<1, ZT_TPB>>>(d_p1, d_pinf, blocks, d_m1, d_minf);
}

// ---- SPLIT-EQ tail (port of the CPU SplitEqGhash structure) ----
//
// The per-round eq table eq(r[7+k..m]) is never materialized. Build once:
//   eqlo = build_eq(r[7 .. 7+lobits])       (2^lobits entries, lobits = (m-7)-7)
//   eqhi = build_eq(r[7+lobits .. m])       (<= 2^7 = 128 entries)
// Then for the round that has dropped the k lowest of these vars (k=0 is the
// round-2 message, tail round i has k=i+1), with z = y << k:
//   eq(r[7+k..m])[y] = S_k · eqlo[z & (2^lobits-1)] · eqhi[z >> lobits]
// because build_eq puts a (1+r_j) factor at every zero bit, so the shifted-in
// low zero bits contribute exactly Π_{j=7}^{6+k}(1+r_j) — cancelled by the host
// scalar S_k = Π_{j=7}^{6+k}(1+r_j)^{-1}, applied once to the two message sums
// in the combine kernel (GF(2^128) is exact, so this is bit-identical to the
// materialized eq). Kills the per-round eq_halve_scale pass and the full-size
// eq stream in the message: eqlo/eqhi are small enough to live in L2.
__device__ __forceinline__ F128 evaluate_zerocheck_split_equality(const F128* __restrict__ eqlo,
                                            const F128* __restrict__ eqhi,
                                            long long z, int lobits) {
    return ghash_mul_karatsuba(eqlo[z & ((1LL << lobits) - 1)], eqhi[z >> lobits]);
}

__global__ void combine_scaled_zerocheck_tail_message(const F128* p1, const F128* pinf, int blocks,
                                      F128 scale, F128* m1, F128* minf) {
    __shared__ F128 s1[ZT_TPB];
    __shared__ F128 sinf[ZT_TPB];
    F128 a1{0, 0}, ai{0, 0};
    for (int b = threadIdx.x; b < blocks; b += blockDim.x) { a1 = f128_add(a1, p1[b]); ai = f128_add(ai, pinf[b]); }
    int x = threadIdx.x;
    s1[x] = a1; sinf[x] = ai;
    __syncthreads();
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (x < s) { s1[x] = f128_add(s1[x], s1[x + s]); sinf[x] = f128_add(sinf[x], sinf[x + s]); }
        __syncthreads();
    }
    if (x == 0) { *m1 = ghash_mul_karatsuba(s1[0], scale); *minf = ghash_mul_karatsuba(sinf[0], scale); }
}

__global__ void zerocheck_tail_message_split(const F128* __restrict__ A, const F128* __restrict__ B,
                                     const F128* __restrict__ eqlo, const F128* __restrict__ eqhi,
                                     int shift, int lobits, long long half,
                                     F128* p1, F128* pinf) {
    __shared__ F128 s1[ZT_TPB];
    __shared__ F128 sinf[ZT_TPB];
    long long t = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    long long stride = (long long)gridDim.x * blockDim.x;
    F128 g1{0, 0}, ginf{0, 0};
    for (long long x = t; x < half; x += stride) {
        F128 a0 = A[2 * x], a1 = A[2 * x + 1];
        F128 b0 = B[2 * x], b1 = B[2 * x + 1];
        F128 e = evaluate_zerocheck_split_equality(eqlo, eqhi, x << shift, lobits);
        g1 = f128_add(g1, ghash_mul_karatsuba(e, ghash_mul_karatsuba(a1, b1)));
        ginf = f128_add(ginf, ghash_mul_karatsuba(e, ghash_mul_karatsuba(
                                  f128_add(a0, a1), f128_add(b0, b1))));
    }
    int x = threadIdx.x;
    s1[x] = g1; sinf[x] = ginf;
    __syncthreads();
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (x < s) { s1[x] = f128_add(s1[x], s1[x + s]); sinf[x] = f128_add(sinf[x], sinf[x + s]); }
        __syncthreads();
    }
    if (x == 0) { p1[blockIdx.x] = s1[0]; pinf[blockIdx.x] = sinf[0]; }
}

__global__ void zerocheck_tail_fold_and_message_split(const F128* __restrict__ A, const F128* __restrict__ B,
                                          F128* __restrict__ Ao, F128* __restrict__ Bo,
                                          const F128* __restrict__ eqlo, const F128* __restrict__ eqhi,
                                          int shift, int lobits, long long out_pairs, F128 r,
                                          F128* p1, F128* pinf) {
    __shared__ F128 s1[ZT_TPB];
    __shared__ F128 sinf[ZT_TPB];
    long long t = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    long long stride = (long long)gridDim.x * blockDim.x;
    F128 g1{0, 0}, ginf{0, 0};
    for (long long x = t; x < out_pairs; x += stride) {
        long long i = 4 * x;
        F128 a0 = A[i], a1 = A[i + 1], a2 = A[i + 2], a3 = A[i + 3];
        F128 b0 = B[i], b1 = B[i + 1], b2 = B[i + 2], b3 = B[i + 3];
        F128 af0 = f128_add(a0, ghash_mul_karatsuba(r, f128_add(a0, a1)));
        F128 af1 = f128_add(a2, ghash_mul_karatsuba(r, f128_add(a2, a3)));
        F128 bf0 = f128_add(b0, ghash_mul_karatsuba(r, f128_add(b0, b1)));
        F128 bf1 = f128_add(b2, ghash_mul_karatsuba(r, f128_add(b2, b3)));
        Ao[2 * x] = af0; Ao[2 * x + 1] = af1; Bo[2 * x] = bf0; Bo[2 * x + 1] = bf1;
        F128 e = evaluate_zerocheck_split_equality(eqlo, eqhi, x << shift, lobits);
        g1 = f128_add(g1, ghash_mul_karatsuba(e, ghash_mul_karatsuba(af1, bf1)));
        ginf = f128_add(ginf, ghash_mul_karatsuba(e, ghash_mul_karatsuba(
                                  f128_add(af0, af1), f128_add(bf0, bf1))));
    }
    int x = threadIdx.x;
    s1[x] = g1; sinf[x] = ginf;
    __syncthreads();
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (x < s) { s1[x] = f128_add(s1[x], s1[x + s]); sinf[x] = f128_add(sinf[x], sinf[x + s]); }
        __syncthreads();
    }
    if (x == 0) { p1[blockIdx.x] = s1[0]; pinf[blockIdx.x] = sinf[0]; }
}

// Device-rho split variant (for the resident on-device-challenger tail).
__global__ void zerocheck_tail_fold_and_message_split_device_challenge(const F128* __restrict__ A, const F128* __restrict__ B,
                                              F128* __restrict__ Ao, F128* __restrict__ Bo,
                                              const F128* __restrict__ eqlo, const F128* __restrict__ eqhi,
                                              int shift, int lobits, long long out_pairs,
                                              const F128* __restrict__ r_ptr,
                                              F128* p1, F128* pinf) {
    __shared__ F128 s1[ZT_TPB];
    __shared__ F128 sinf[ZT_TPB];
    F128 r = *r_ptr;
    long long t = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    long long stride = (long long)gridDim.x * blockDim.x;
    F128 g1{0, 0}, ginf{0, 0};
    for (long long x = t; x < out_pairs; x += stride) {
        long long i = 4 * x;
        F128 a0 = A[i], a1 = A[i + 1], a2 = A[i + 2], a3 = A[i + 3];
        F128 b0 = B[i], b1 = B[i + 1], b2 = B[i + 2], b3 = B[i + 3];
        F128 af0 = f128_add(a0, ghash_mul_karatsuba(r, f128_add(a0, a1)));
        F128 af1 = f128_add(a2, ghash_mul_karatsuba(r, f128_add(a2, a3)));
        F128 bf0 = f128_add(b0, ghash_mul_karatsuba(r, f128_add(b0, b1)));
        F128 bf1 = f128_add(b2, ghash_mul_karatsuba(r, f128_add(b2, b3)));
        Ao[2 * x] = af0; Ao[2 * x + 1] = af1; Bo[2 * x] = bf0; Bo[2 * x + 1] = bf1;
        F128 e = evaluate_zerocheck_split_equality(eqlo, eqhi, x << shift, lobits);
        g1 = f128_add(g1, ghash_mul_karatsuba(e, ghash_mul_karatsuba(af1, bf1)));
        ginf = f128_add(ginf, ghash_mul_karatsuba(e, ghash_mul_karatsuba(
                                  f128_add(af0, af1), f128_add(bf0, bf1))));
    }
    int x = threadIdx.x;
    s1[x] = g1; sinf[x] = ginf;
    __syncthreads();
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (x < s) { s1[x] = f128_add(s1[x], s1[x + s]); sinf[x] = f128_add(sinf[x], sinf[x + s]); }
        __syncthreads();
    }
    if (x == 0) { p1[blockIdx.x] = s1[0]; pinf[blockIdx.x] = sinf[0]; }
}

// ---- hi-factored variants (the CPU SplitEqGhash inner-loop structure) ----
//
// When each block's contiguous point range maps to a SINGLE eqhi entry, the
// per-point mul is eqlo only; the block's partial sums are multiplied by that
// one eqhi value at the end of the shared-memory reduction (2 muls per block
// instead of 1 per point). Distributivity over the XOR-sum is exact in
// GF(2^128), so this is bit-identical to the per-point form. These kernels use
// contiguous per-block chunks (not grid-stride): block b owns points
// [b·chunk, (b+1)·chunk); plan_zerocheck_high_bits checks the single-eqhi condition
// (power-of-two chunk with chunk·2^shift ≤ 2^lobits ⇒ every chunk lies inside
// one eqhi segment) — callers fall back to the per-point kernels otherwise
// (only the tiny latency-bound rounds).
inline bool plan_zerocheck_high_bits(long long n, int shift, int lobits, int blocks, long long& chunk) {
    if (n <= 0 || (n & (n - 1))) return false;
    chunk = (n + blocks - 1) / blocks;
    if (chunk & (chunk - 1)) return false;
    return (chunk << shift) <= (1LL << lobits);
}

__global__ void zerocheck_tail_message_split_high_bits(const F128* __restrict__ A, const F128* __restrict__ B,
                                         const F128* __restrict__ eqlo, const F128* __restrict__ eqhi,
                                         int shift, int lobits, long long half, long long chunk,
                                         F128* p1, F128* pinf) {
    __shared__ F128 s1[ZT_TPB];
    __shared__ F128 sinf[ZT_TPB];
    long long start = (long long)blockIdx.x * chunk;
    long long end = start + chunk < half ? start + chunk : half;
    F256 g1{0, 0, 0, 0}, ginf{0, 0, 0, 0};   // deferred reduction (ghash_reduce is F2-linear)
    for (long long x = start + threadIdx.x; x < end; x += blockDim.x) {
        F128 a0 = A[2 * x], a1 = A[2 * x + 1];
        F128 b0 = B[2 * x], b1 = B[2 * x + 1];
        F128 e = eqlo[(x << shift) & ((1LL << lobits) - 1)];
        f256_xor(g1, mul_unreduced_karatsuba(e, ghash_mul_karatsuba(a1, b1)));
        f256_xor(ginf, mul_unreduced_karatsuba(e, ghash_mul_karatsuba(
                                  f128_add(a0, a1), f128_add(b0, b1))));
    }
    int x = threadIdx.x;
    s1[x] = f256_reduce(g1); sinf[x] = f256_reduce(ginf);
    __syncthreads();
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (x < s) { s1[x] = f128_add(s1[x], s1[x + s]); sinf[x] = f128_add(sinf[x], sinf[x + s]); }
        __syncthreads();
    }
    if (x == 0) {
        if (start < half) {
            F128 eh = eqhi[(start << shift) >> lobits];
            p1[blockIdx.x] = ghash_mul_karatsuba(s1[0], eh);
            pinf[blockIdx.x] = ghash_mul_karatsuba(sinf[0], eh);
        } else { p1[blockIdx.x] = F128{0, 0}; pinf[blockIdx.x] = F128{0, 0}; }
    }
}

__global__ void zerocheck_tail_fold_and_message_split_high_bits(const F128* __restrict__ A, const F128* __restrict__ B,
                                              F128* __restrict__ Ao, F128* __restrict__ Bo,
                                              const F128* __restrict__ eqlo, const F128* __restrict__ eqhi,
                                              int shift, int lobits, long long out_pairs, long long chunk,
                                              F128 r, F128* p1, F128* pinf) {
    __shared__ F128 s1[ZT_TPB];
    __shared__ F128 sinf[ZT_TPB];
    long long start = (long long)blockIdx.x * chunk;
    long long end = start + chunk < out_pairs ? start + chunk : out_pairs;
    F256 g1{0, 0, 0, 0}, ginf{0, 0, 0, 0};   // deferred reduction (ghash_reduce is F2-linear)
    for (long long x = start + threadIdx.x; x < end; x += blockDim.x) {
        long long i = 4 * x;
        F128 a0 = A[i], a1 = A[i + 1], a2 = A[i + 2], a3 = A[i + 3];
        F128 b0 = B[i], b1 = B[i + 1], b2 = B[i + 2], b3 = B[i + 3];
        F128 af0 = f128_add(a0, ghash_mul_karatsuba(r, f128_add(a0, a1)));
        F128 af1 = f128_add(a2, ghash_mul_karatsuba(r, f128_add(a2, a3)));
        F128 bf0 = f128_add(b0, ghash_mul_karatsuba(r, f128_add(b0, b1)));
        F128 bf1 = f128_add(b2, ghash_mul_karatsuba(r, f128_add(b2, b3)));
        Ao[2 * x] = af0; Ao[2 * x + 1] = af1; Bo[2 * x] = bf0; Bo[2 * x + 1] = bf1;
        F128 e = eqlo[(x << shift) & ((1LL << lobits) - 1)];
        f256_xor(g1, mul_unreduced_karatsuba(e, ghash_mul_karatsuba(af1, bf1)));
        f256_xor(ginf, mul_unreduced_karatsuba(e, ghash_mul_karatsuba(
                                  f128_add(af0, af1), f128_add(bf0, bf1))));
    }
    int x = threadIdx.x;
    s1[x] = f256_reduce(g1); sinf[x] = f256_reduce(ginf);
    __syncthreads();
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (x < s) { s1[x] = f128_add(s1[x], s1[x + s]); sinf[x] = f128_add(sinf[x], sinf[x + s]); }
        __syncthreads();
    }
    if (x == 0) {
        if (start < out_pairs) {
            F128 eh = eqhi[(start << shift) >> lobits];
            p1[blockIdx.x] = ghash_mul_karatsuba(s1[0], eh);
            pinf[blockIdx.x] = ghash_mul_karatsuba(sinf[0], eh);
        } else { p1[blockIdx.x] = F128{0, 0}; pinf[blockIdx.x] = F128{0, 0}; }
    }
}

__global__ void zerocheck_tail_fold_and_message_split_high_bits_device_challenge(const F128* __restrict__ A, const F128* __restrict__ B,
                                                  F128* __restrict__ Ao, F128* __restrict__ Bo,
                                                  const F128* __restrict__ eqlo, const F128* __restrict__ eqhi,
                                                  int shift, int lobits, long long out_pairs, long long chunk,
                                                  const F128* __restrict__ r_ptr, F128* p1, F128* pinf) {
    __shared__ F128 s1[ZT_TPB];
    __shared__ F128 sinf[ZT_TPB];
    F128 r = *r_ptr;
    long long start = (long long)blockIdx.x * chunk;
    long long end = start + chunk < out_pairs ? start + chunk : out_pairs;
    F256 g1{0, 0, 0, 0}, ginf{0, 0, 0, 0};   // deferred reduction (ghash_reduce is F2-linear)
    for (long long x = start + threadIdx.x; x < end; x += blockDim.x) {
        long long i = 4 * x;
        F128 a0 = A[i], a1 = A[i + 1], a2 = A[i + 2], a3 = A[i + 3];
        F128 b0 = B[i], b1 = B[i + 1], b2 = B[i + 2], b3 = B[i + 3];
        F128 af0 = f128_add(a0, ghash_mul_karatsuba(r, f128_add(a0, a1)));
        F128 af1 = f128_add(a2, ghash_mul_karatsuba(r, f128_add(a2, a3)));
        F128 bf0 = f128_add(b0, ghash_mul_karatsuba(r, f128_add(b0, b1)));
        F128 bf1 = f128_add(b2, ghash_mul_karatsuba(r, f128_add(b2, b3)));
        Ao[2 * x] = af0; Ao[2 * x + 1] = af1; Bo[2 * x] = bf0; Bo[2 * x + 1] = bf1;
        F128 e = eqlo[(x << shift) & ((1LL << lobits) - 1)];
        f256_xor(g1, mul_unreduced_karatsuba(e, ghash_mul_karatsuba(af1, bf1)));
        f256_xor(ginf, mul_unreduced_karatsuba(e, ghash_mul_karatsuba(
                                  f128_add(af0, af1), f128_add(bf0, bf1))));
    }
    int x = threadIdx.x;
    s1[x] = f256_reduce(g1); sinf[x] = f256_reduce(ginf);
    __syncthreads();
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (x < s) { s1[x] = f128_add(s1[x], s1[x + s]); sinf[x] = f128_add(sinf[x], sinf[x + s]); }
        __syncthreads();
    }
    if (x == 0) {
        if (start < out_pairs) {
            F128 eh = eqhi[(start << shift) >> lobits];
            p1[blockIdx.x] = ghash_mul_karatsuba(s1[0], eh);
            pinf[blockIdx.x] = ghash_mul_karatsuba(sinf[0], eh);
        } else { p1[blockIdx.x] = F128{0, 0}; pinf[blockIdx.x] = F128{0, 0}; }
    }
}

// ---- TWO-ROUND LOOKAHEAD ----
//
// One pass produces TWO rounds' messages. Round k's message is the usual
// (g_one, g_inf) over the folded array. Round k+1's message cannot be evaluated
// yet — it depends on rho_k, which Fiat-Shamir only yields after round k is
// observed — but as a function of rho_k each of its two components is a
// QUADRATIC (a product of two rho_k-linear folds), so three evaluations pin it
// down exactly. The kernel accumulates those at rho_k in {0, 1, inf} and the
// host interpolates once rho_k is known.
//
// Costed against the one-round-per-pass loop it replaces, over two rounds of an
// array of length L (both arrays, 16 B/elem): that loop moves 2L read + L
// written, then L read + L/2 written = 4.5L. Folding twice per pass moves
// 2L read + L/2 written = 2.5L, and the geometric series over the whole tail
// falls from 6L to 3.33L. Mul count drops too (42 per output quad vs 48).
//
// NFOLD is the number of folds applied on the way in: 1 for the bootstrap pass
// (only rho_0 is in hand), 2 once the previous pass has left two rhos pending.
static __device__ __forceinline__ F128 zt_fold1(F128 a0, F128 a1, F128 r) {
    return f128_add(a0, ghash_mul_karatsuba(r, f128_add(a0, a1)));
}
static __device__ __forceinline__ F128 zt_fold_elem2(const F128* __restrict__ X, long long t,
                                                     F128 r1, F128 r2) {
    long long b = 4 * t;
    return zt_fold1(zt_fold1(X[b], X[b + 1], r1), zt_fold1(X[b + 2], X[b + 3], r1), r2);
}

// Accumulate one output quad into the eight lookahead slots. w/x are the quad's
// four folded A/B values; e0 and e1 are the split-eq values of round k's message
// pairs 2z and 2z+1. Round k+1's pair z has split-eq index z << (shift+1) ==
// (2z) << shift, so it reuses e0 and differs only in the host scale.
// Slots: 0,1 = round k (g_one, g_inf); 2,3,4 = round k+1 g_one at rho_k in
// {0, 1, inf}; 5,6,7 = round k+1 g_inf likewise.
// Accumulators are unreduced F256: ghash_reduce is F2-linear, so the eq-weighted
// products can be XOR-summed unreduced and reduced once at the end. That drops 10
// reductions per quad, which matters because the round-2 fold is otherwise pure
// table lookups and the added mul work pushes it off the bandwidth roof.
static __device__ __forceinline__ void zt_accum_quad(F256* acc, const F128* w, const F128* x,
                                                     F128 e0, F128 e1) {
    F128 p_1   = ghash_mul_karatsuba(w[1], x[1]);
    F128 p_2   = ghash_mul_karatsuba(w[2], x[2]);
    F128 p_3   = ghash_mul_karatsuba(w[3], x[3]);
    F128 p_01  = ghash_mul_karatsuba(f128_add(w[0], w[1]), f128_add(x[0], x[1]));
    F128 p_23  = ghash_mul_karatsuba(f128_add(w[2], w[3]), f128_add(x[2], x[3]));
    F128 p_02  = ghash_mul_karatsuba(f128_add(w[0], w[2]), f128_add(x[0], x[2]));
    F128 p_13  = ghash_mul_karatsuba(f128_add(w[1], w[3]), f128_add(x[1], x[3]));
    F128 p_all = ghash_mul_karatsuba(f128_add(f128_add(w[0], w[1]), f128_add(w[2], w[3])),
                                     f128_add(f128_add(x[0], x[1]), f128_add(x[2], x[3])));
    f256_xor(acc[0], mul_unreduced_karatsuba(e0, p_1));
    f256_xor(acc[0], mul_unreduced_karatsuba(e1, p_3));
    f256_xor(acc[1], mul_unreduced_karatsuba(e0, p_01));
    f256_xor(acc[1], mul_unreduced_karatsuba(e1, p_23));
    f256_xor(acc[2], mul_unreduced_karatsuba(e0, p_2));
    f256_xor(acc[3], mul_unreduced_karatsuba(e0, p_3));
    f256_xor(acc[4], mul_unreduced_karatsuba(e0, p_23));
    f256_xor(acc[5], mul_unreduced_karatsuba(e0, p_02));
    f256_xor(acc[6], mul_unreduced_karatsuba(e0, p_13));
    f256_xor(acc[7], mul_unreduced_karatsuba(e0, p_all));
}

// Block-reduce the eight slots into part[8][gridDim.x], scaling each by blockmul.
// Hi-factored callers pass their block's single eqhi value (see plan_zerocheck_high_bits);
// per-point callers pass ONE. One shared buffer reused eight times: 8 x ZT_TPB
// F128 at once is 32 KB per block and would gut occupancy.
static __device__ __forceinline__ void zt_reduce8(F256* acc, F128* sh, F128* __restrict__ part,
                                                  F128 blockmul) {
    for (int j = 0; j < 8; j++) {
        sh[threadIdx.x] = f256_reduce(acc[j]);
        __syncthreads();
        for (int s = blockDim.x / 2; s > 0; s >>= 1) {
            if ((int)threadIdx.x < s) sh[threadIdx.x] = f128_add(sh[threadIdx.x], sh[threadIdx.x + s]);
            __syncthreads();
        }
        if (threadIdx.x == 0)
            part[(long long)j * gridDim.x + blockIdx.x] = ghash_mul_karatsuba(sh[0], blockmul);
        __syncthreads();
    }
}

// Fold twice by (r1, r2) and accumulate both rounds' message data in one pass.
// out_quads = (folded array length) / 4; each thread owns one output quad, i.e.
// 16 input elements per array. The round-2 kernel supplies both pending rhos, so
// there is no single-fold bootstrap: measured end-to-end, a fold-once first pass
// costs more in tail bandwidth than it saves in round-2 multiplies.
__global__ void zerocheck_tail_lookahead_fold_and_message(const F128* __restrict__ A, const F128* __restrict__ B,
                               F128* __restrict__ Ao, F128* __restrict__ Bo,
                               const F128* __restrict__ eqlo, const F128* __restrict__ eqhi,
                               int shift, int lobits, long long out_quads,
                               F128 r1, F128 r2, F128* __restrict__ part) {
    __shared__ F128 sh[ZT_TPB];
    F256 acc[8];
#pragma unroll
    for (int j = 0; j < 8; j++) acc[j] = F256{0, 0, 0, 0};

    long long t = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    long long stride = (long long)gridDim.x * blockDim.x;
    for (long long z = t; z < out_quads; z += stride) {
        long long o = 4 * z;
        F128 w[4], x[4];
#pragma unroll
        for (int j = 0; j < 4; j++) {
            w[j] = zt_fold_elem2(A, o + j, r1, r2);
            x[j] = zt_fold_elem2(B, o + j, r1, r2);
            Ao[o + j] = w[j]; Bo[o + j] = x[j];
        }
        zt_accum_quad(acc, w, x,
                      evaluate_zerocheck_split_equality(eqlo, eqhi, (z << 1) << shift, lobits),
                      evaluate_zerocheck_split_equality(eqlo, eqhi, ((z << 1) + 1) << shift, lobits));
    }
    zt_reduce8(acc, sh, part, F128{1, 0});
}

// Block j reduces accumulator j and applies its round's scale: slots 0,1 belong to
// round k, slots 2..7 to round k+1.
__global__ void combine_zerocheck_tail_lookahead_message(const F128* __restrict__ part, int blocks,
                                F128 scale_k, F128 scale_k1, F128* __restrict__ out) {
    __shared__ F128 sh[ZT_TPB];
    int j = blockIdx.x;
    F128 a{0, 0};
    for (int b = threadIdx.x; b < blocks; b += blockDim.x)
        a = f128_add(a, part[(long long)j * blocks + b]);
    sh[threadIdx.x] = a;
    __syncthreads();
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if ((int)threadIdx.x < s) sh[threadIdx.x] = f128_add(sh[threadIdx.x], sh[threadIdx.x + s]);
        __syncthreads();
    }
    if (threadIdx.x == 0) out[j] = ghash_mul_karatsuba(sh[0], j < 2 ? scale_k : scale_k1);
}

// d_out receives 8 F128 (see the slot layout on zt_accum_quad).
// d_part needs 8 * ZT_MAX_BLOCKS entries.
inline void launch_zerocheck_tail_lookahead(const F128* dA, const F128* dB, F128* dAo, F128* dBo,
                                const F128* dEqLo, const F128* dEqHi, int shift, int lobits,
                                long long out_quads, F128 r1, F128 r2,
                                F128 scale_k, F128 scale_k1, F128* d_part, F128* d_out) {
    int blocks = zt_blocks(out_quads);
    zerocheck_tail_lookahead_fold_and_message<<<blocks, ZT_TPB>>>(dA, dB, dAo, dBo, dEqLo, dEqHi, shift, lobits,
                                       out_quads, r1, r2, d_part);
    combine_zerocheck_tail_lookahead_message<<<8, ZT_TPB>>>(d_part, blocks, scale_k, scale_k1, d_out);
}

inline void launch_zerocheck_tail_message(const F128* dA, const F128* dB,
                                const F128* dEqLo, const F128* dEqHi, int shift, int lobits,
                                long long half, F128 scale,
                                F128* d_p1, F128* d_pinf, F128* d_m1, F128* d_minf) {
    int blocks = zt_blocks(half);
    long long chunk;
    if (plan_zerocheck_high_bits(half, shift, lobits, blocks, chunk))
        zerocheck_tail_message_split_high_bits<<<blocks, ZT_TPB>>>(dA, dB, dEqLo, dEqHi, shift, lobits, half, chunk,
                                                     d_p1, d_pinf);
    else
        zerocheck_tail_message_split<<<blocks, ZT_TPB>>>(dA, dB, dEqLo, dEqHi, shift, lobits, half, d_p1, d_pinf);
    combine_scaled_zerocheck_tail_message<<<1, ZT_TPB>>>(d_p1, d_pinf, blocks, scale, d_m1, d_minf);
}

inline void launch_zerocheck_tail_fold_and_message(const F128* dA, const F128* dB, F128* dAo, F128* dBo,
                                     const F128* dEqLo, const F128* dEqHi, int shift, int lobits,
                                     long long out_pairs, F128 r, F128 scale,
                                     F128* d_p1, F128* d_pinf, F128* d_m1, F128* d_minf) {
    int blocks = zt_blocks(out_pairs);
    long long chunk;
    if (plan_zerocheck_high_bits(out_pairs, shift, lobits, blocks, chunk))
        zerocheck_tail_fold_and_message_split_high_bits<<<blocks, ZT_TPB>>>(dA, dB, dAo, dBo, dEqLo, dEqHi, shift, lobits,
                                                          out_pairs, chunk, r, d_p1, d_pinf);
    else
        zerocheck_tail_fold_and_message_split<<<blocks, ZT_TPB>>>(dA, dB, dAo, dBo, dEqLo, dEqHi, shift, lobits,
                                                      out_pairs, r, d_p1, d_pinf);
    combine_scaled_zerocheck_tail_message<<<1, ZT_TPB>>>(d_p1, d_pinf, blocks, scale, d_m1, d_minf);
}

inline void launch_zerocheck_tail_fold_and_message_device_challenge(const F128* dA, const F128* dB, F128* dAo, F128* dBo,
                                         const F128* dEqLo, const F128* dEqHi, int shift, int lobits,
                                         long long out_pairs, const F128* d_r, F128 scale,
                                         F128* d_p1, F128* d_pinf, F128* d_m1, F128* d_minf) {
    int blocks = zt_blocks(out_pairs);
    long long chunk;
    if (plan_zerocheck_high_bits(out_pairs, shift, lobits, blocks, chunk))
        zerocheck_tail_fold_and_message_split_high_bits_device_challenge<<<blocks, ZT_TPB>>>(dA, dB, dAo, dBo, dEqLo, dEqHi, shift, lobits,
                                                              out_pairs, chunk, d_r, d_p1, d_pinf);
    else
        zerocheck_tail_fold_and_message_split_device_challenge<<<blocks, ZT_TPB>>>(dA, dB, dAo, dBo, dEqLo, dEqHi, shift, lobits,
                                                          out_pairs, d_r, d_p1, d_pinf);
    combine_scaled_zerocheck_tail_message<<<1, ZT_TPB>>>(d_p1, d_pinf, blocks, scale, d_m1, d_minf);
}
