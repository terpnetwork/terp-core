// a·b multilinear sumcheck kernels — step 3 of the GPU pcs::open (Ligerito)
// port. The degree-2 sumcheck of S = Σ_x a(x)·b(x) that
// the Ligerito prover runs over `(f, combined_basis)`
// (`src/pcs/ligerito.rs`'s `SumcheckProver` / `fold_and_msg_lsb`).
//
// Per round, over the CURRENT a,b with ADJACENT pairing (a[2j], a[2j+1]) —
// matching the CPU prover instead of a strided (i, i+half) layout:
//   message:  u_0 = Σ_j a[2j]·b[2j]                     (= u(0))
//             u_2 = Σ_j (a[2j]+a[2j+1])·(b[2j]+b[2j+1]) (= u(∞), leading coeff)
//   fold:     a'[j] = a[2j] + r·(a[2j]+a[2j+1])  (and b)
// The middle coeff is recovered by the verifier from the running claim, so only
// {u_0, u_2} are produced (the CPU `SumcheckMessage`).
//
// The message is a global reduction: reduce-per-term (F128 accumulate). Deferred
// reduction (F256, reduce once) was measured a wash-to-slight-loss on this GPU
// and doubles the reduction-tree's shared memory, so plain F128 is used. Two-pass
// per round (message reduce, then fold) for correctness-first clarity; fusing the next
// round's message into the fold (as `fold_and_msg_lsb` does) is the later optimization.
#pragma once
#include "f128.cuh"

#ifndef SMC_TPB
#define SMC_TPB 256
#endif

// Block-partial message reduction (adjacent pairing). Grid-stride so the
// launched block count can be capped; each block writes one (p0, p2) F128.
__global__ void sumcheck_message_partial(const F128* __restrict__ A,
                                     const F128* __restrict__ B,
                                     long long half, F128* p0, F128* p2) {
    // Reduce-per-term (F128) rather than deferred (F256): halves shared memory
    // (better occupancy) and is a measured wash-to-win on this GPU, since
    // ghash_reduce pipelines behind the CLMAD multiply. Bit-identical.
    __shared__ F128 s0[SMC_TPB];
    __shared__ F128 s2[SMC_TPB];
    long long t = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    long long stride = (long long)gridDim.x * blockDim.x;
    F128 e0{0, 0}, e2{0, 0};
    for (long long j = t; j < half; j += stride) {
        F128 a0 = A[2 * j], a1 = A[2 * j + 1];
        F128 b0 = B[2 * j], b1 = B[2 * j + 1];
        e0 = f128_add(e0, ghash_mul_karatsuba(a0, b0));
        e2 = f128_add(e2, ghash_mul_karatsuba(f128_add(a0, a1), f128_add(b0, b1)));
    }
    int x = threadIdx.x;
    s0[x] = e0; s2[x] = e2;
    __syncthreads();
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (x < s) { s0[x] = f128_add(s0[x], s0[x + s]); s2[x] = f128_add(s2[x], s2[x + s]); }
        __syncthreads();
    }
    if (x == 0) { p0[blockIdx.x] = s0[0]; p2[blockIdx.x] = s2[0]; }
}

// Combine block partials → u_0, u_2. One 256-thread block: the single-thread
// loop this replaces cost ~200 us at 2048 blocks — same order as the partial
// kernel itself. XOR order is irrelevant → bit-identical.
__global__ void combine_sumcheck_message(const F128* p0, const F128* p2, int blocks,
                                     F128* u0, F128* u2) {
    __shared__ F128 s0[SMC_TPB];
    __shared__ F128 s2[SMC_TPB];
    F128 a0{0, 0}, a2{0, 0};
    for (int b = threadIdx.x; b < blocks; b += blockDim.x) { a0 = f128_add(a0, p0[b]); a2 = f128_add(a2, p2[b]); }
    int x = threadIdx.x;
    s0[x] = a0; s2[x] = a2;
    __syncthreads();
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (x < s) { s0[x] = f128_add(s0[x], s0[x + s]); s2[x] = f128_add(s2[x], s2[x + s]); }
        __syncthreads();
    }
    if (x == 0) { *u0 = s0[0]; *u2 = s2[0]; }
}

// Fold a,b by r (adjacent pairing), ping-pong: out[j] from in[2j],in[2j+1].
__global__ void sumcheck_fold(const F128* __restrict__ A, const F128* __restrict__ B,
                              F128* __restrict__ Ao, F128* __restrict__ Bo,
                              long long half, F128 r) {
    long long j = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    if (j >= half) return;
    F128 a0 = A[2 * j], a1 = A[2 * j + 1];
    F128 b0 = B[2 * j], b1 = B[2 * j + 1];
    Ao[j] = f128_add(a0, ghash_mul_karatsuba(r, f128_add(a0, a1)));
    Bo[j] = f128_add(b0, ghash_mul_karatsuba(r, f128_add(b0, b1)));
}

// FUSED fold + next-round message (ligerito's fold_and_msg_lsb). One pass over
// (A,B): fold by r into (Ao,Bo), AND accumulate the message of the FOLDED arrays
// (= the next round's {u_0,u_2}) — so A,B are read once per round instead of
// twice (separate message pass eliminated). Each thread handles one output PAIR
// (Ao[2j],Ao[2j+1]) from inputs A[4j..4j+4]; out_pairs = half/2 (half=folded len).
// Requires half>=2 (even); the lone half==1 tail uses sumcheck_fold + zero msg.
__global__ void sumcheck_fold_and_message_partial(const F128* __restrict__ A, const F128* __restrict__ B,
                                          F128* __restrict__ Ao, F128* __restrict__ Bo,
                                          long long out_pairs, F128 r, F128* p0, F128* p2) {
    __shared__ F128 s0[SMC_TPB];
    __shared__ F128 s2[SMC_TPB];
    long long t = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    long long stride = (long long)gridDim.x * blockDim.x;
    F128 e0{0, 0}, e2{0, 0};
    for (long long j = t; j < out_pairs; j += stride) {
        long long i = 4 * j;
        F128 a0 = A[i], a1 = A[i + 1], a2 = A[i + 2], a3 = A[i + 3];
        F128 b0 = B[i], b1 = B[i + 1], b2 = B[i + 2], b3 = B[i + 3];
        F128 af0 = f128_add(a0, ghash_mul_karatsuba(r, f128_add(a0, a1)));  // fold pair 2j
        F128 af1 = f128_add(a2, ghash_mul_karatsuba(r, f128_add(a2, a3)));  // fold pair 2j+1
        F128 bf0 = f128_add(b0, ghash_mul_karatsuba(r, f128_add(b0, b1)));
        F128 bf1 = f128_add(b2, ghash_mul_karatsuba(r, f128_add(b2, b3)));
        Ao[2 * j] = af0; Ao[2 * j + 1] = af1; Bo[2 * j] = bf0; Bo[2 * j + 1] = bf1;
        e0 = f128_add(e0, ghash_mul_karatsuba(af0, bf0));                                  // u_0 over folded
        e2 = f128_add(e2, ghash_mul_karatsuba(f128_add(af0, af1), f128_add(bf0, bf1)));    // u_2 over folded
    }
    int x = threadIdx.x;
    s0[x] = e0; s2[x] = e2;
    __syncthreads();
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (x < s) { s0[x] = f128_add(s0[x], s0[x + s]); s2[x] = f128_add(s2[x], s2[x + s]); }
        __syncthreads();
    }
    if (x == 0) { p0[blockIdx.x] = s0[0]; p2[blockIdx.x] = s2[0]; }
}

// Host driver for one round's message: returns (u_0, u_2) on device. `d_p0`,
// ---- TWO-ROUND LOOKAHEAD ----
//
// Same idea as zerocheck_tail.cuh: one pass yields two rounds' messages. Round
// k's is the usual (u_0, u_2); round k+1's is a quadratic in rho_k, so three
// evaluations at rho_k in {0, 1, inf} pin it down and the host interpolates.
//
// This sumcheck has no eq weighting, so the lookahead is strictly cheaper on
// BOTH axes than one round per pass: over two rounds of a length-L array it
// moves 2.5L instead of 4.5L, and costs 2L multiplies instead of 2.25L. The
// measured fold phase runs at 1.33 TB/s (~92% of this GPU's ceiling) and only
// 41 G muls/s, so it is bandwidth-bound with ample compute headroom.
//
// Slots: 0,1 = round k (u_0, u_2); 2,3,4 = round k+1's u_0 at rho_k in
// {0, 1, inf}; 5,6,7 = its u_2 likewise. Accumulators are plain F128 — every
// product here is already reduced, so there is nothing to defer.
static __device__ __forceinline__ void sc_accum_quad(F128* acc, const F128* v, const F128* w) {
    F128 P00  = ghash_mul_karatsuba(v[0], w[0]);
    F128 P11  = ghash_mul_karatsuba(v[1], w[1]);
    F128 P22  = ghash_mul_karatsuba(v[2], w[2]);
    F128 P01  = ghash_mul_karatsuba(f128_add(v[0], v[1]), f128_add(w[0], w[1]));
    F128 P23  = ghash_mul_karatsuba(f128_add(v[2], v[3]), f128_add(w[2], w[3]));
    F128 P02  = ghash_mul_karatsuba(f128_add(v[0], v[2]), f128_add(w[0], w[2]));
    F128 P13  = ghash_mul_karatsuba(f128_add(v[1], v[3]), f128_add(w[1], w[3]));
    F128 Pall = ghash_mul_karatsuba(f128_add(f128_add(v[0], v[1]), f128_add(v[2], v[3])),
                                    f128_add(f128_add(w[0], w[1]), f128_add(w[2], w[3])));
    acc[0] = f128_add(acc[0], f128_add(P00, P22));   // u_0 over pairs 2z, 2z+1
    acc[1] = f128_add(acc[1], f128_add(P01, P23));   // u_2 over pairs 2z, 2z+1
    acc[2] = f128_add(acc[2], P00);
    acc[3] = f128_add(acc[3], P11);
    acc[4] = f128_add(acc[4], P01);
    acc[5] = f128_add(acc[5], P02);
    acc[6] = f128_add(acc[6], P13);
    acc[7] = f128_add(acc[7], Pall);
}

// Block-reduce the eight slots into part[8][gridDim.x], reusing one shared buffer.
static __device__ __forceinline__ void sc_reduce8(F128* acc, F128* sh, F128* __restrict__ part) {
    for (int j = 0; j < 8; j++) {
        sh[threadIdx.x] = acc[j];
        __syncthreads();
        for (int s = blockDim.x / 2; s > 0; s >>= 1) {
            if ((int)threadIdx.x < s) sh[threadIdx.x] = f128_add(sh[threadIdx.x], sh[threadIdx.x + s]);
            __syncthreads();
        }
        if (threadIdx.x == 0) part[(long long)j * gridDim.x + blockIdx.x] = sh[0];
        __syncthreads();
    }
}

// No fold: accumulate both rounds' data straight off (A, B). This is the chunk
// bootstrap — it runs on the side stream under the l0 commit, where the first
// message was already being precomputed, so the extra slots ride along for free
// and the first real pass can then fold TWICE.
__global__ void sumcheck_lookahead_message_partial(const F128* __restrict__ A, const F128* __restrict__ B,
                                      long long quads, F128* __restrict__ part) {
    __shared__ F128 sh[SMC_TPB];
    F128 acc[8];
#pragma unroll
    for (int j = 0; j < 8; j++) acc[j] = F128{0, 0};
    long long t = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    long long stride = (long long)gridDim.x * blockDim.x;
    for (long long z = t; z < quads; z += stride) {
        long long i = 4 * z;
        F128 v[4] = {A[i], A[i + 1], A[i + 2], A[i + 3]};
        F128 w[4] = {B[i], B[i + 1], B[i + 2], B[i + 3]};
        sc_accum_quad(acc, v, w);
    }
    sc_reduce8(acc, sh, part);
}

// Fold twice by (r1, r2) and accumulate both rounds' data over the result.
// out_quads = (folded length) / 4; each thread owns 16 input elements per array.
__global__ void sumcheck_lookahead_fold_and_message_partial(const F128* __restrict__ A, const F128* __restrict__ B,
                                            F128* __restrict__ Ao, F128* __restrict__ Bo,
                                            long long out_quads, F128 r1, F128 r2,
                                            F128* __restrict__ part) {
    __shared__ F128 sh[SMC_TPB];
    F128 acc[8];
#pragma unroll
    for (int j = 0; j < 8; j++) acc[j] = F128{0, 0};
    long long t = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    long long stride = (long long)gridDim.x * blockDim.x;
    for (long long z = t; z < out_quads; z += stride) {
        long long o = 4 * z;
        F128 v[4], w[4];
#pragma unroll
        for (int j = 0; j < 4; j++) {
            long long b = 4 * (o + j);
            F128 va = f128_add(A[b],     ghash_mul_karatsuba(r1, f128_add(A[b],     A[b + 1])));
            F128 vb = f128_add(A[b + 2], ghash_mul_karatsuba(r1, f128_add(A[b + 2], A[b + 3])));
            F128 wa = f128_add(B[b],     ghash_mul_karatsuba(r1, f128_add(B[b],     B[b + 1])));
            F128 wb = f128_add(B[b + 2], ghash_mul_karatsuba(r1, f128_add(B[b + 2], B[b + 3])));
            v[j] = f128_add(va, ghash_mul_karatsuba(r2, f128_add(va, vb)));
            w[j] = f128_add(wa, ghash_mul_karatsuba(r2, f128_add(wa, wb)));
            Ao[o + j] = v[j]; Bo[o + j] = w[j];
        }
        sc_accum_quad(acc, v, w);
    }
    sc_reduce8(acc, sh, part);
}

// Reduce the eight partial rows into d_out[8]; block j owns slot j.
__global__ void combine_sumcheck_lookahead_message(const F128* __restrict__ part, int blocks,
                                      F128* __restrict__ out) {
    __shared__ F128 sh[SMC_TPB];
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
    if (threadIdx.x == 0) out[j] = sh[0];
}

// `d_p2` are scratch of length >= SMC_MAX_BLOCKS.
#ifndef SMC_MAX_BLOCKS
#define SMC_MAX_BLOCKS 2048
#endif

inline int sumcheck_blocks(long long half) {
    long long b = (half + SMC_TPB - 1) / SMC_TPB;
    if (b < 1) b = 1;
    if (b > SMC_MAX_BLOCKS) b = SMC_MAX_BLOCKS;
    return (int)b;
}

inline void launch_sumcheck_message(const F128* dA, const F128* dB, long long half,
                                F128* d_p0, F128* d_p2, F128* d_u0, F128* d_u2) {
    int blocks = sumcheck_blocks(half);
    sumcheck_message_partial<<<blocks, SMC_TPB>>>(dA, dB, half, d_p0, d_p2);
    combine_sumcheck_message<<<1, SMC_TPB>>>(d_p0, d_p2, blocks, d_u0, d_u2);
}

inline void launch_sumcheck_fold(const F128* dA, const F128* dB, F128* dAo, F128* dBo,
                                 long long half, F128 r) {
    long long blocks = (half + SMC_TPB - 1) / SMC_TPB;
    sumcheck_fold<<<(unsigned)blocks, SMC_TPB>>>(dA, dB, dAo, dBo, half, r);
}

// Fused fold-by-r + next-round message in one pass. Folds (dA,dB)→(dAo,dBo) of
// length `half`, and leaves the FOLDED arrays' message in (d_u0,d_u2). half>=2.
inline void launch_sumcheck_fold_and_message(const F128* dA, const F128* dB, F128* dAo, F128* dBo,
                                     long long half, F128 r,
                                     F128* d_p0, F128* d_p2, F128* d_u0, F128* d_u2) {
    if (half < 2) {  // folded length <2 → message is empty (0,0); just fold the tail.
        long long b = (half + SMC_TPB - 1) / SMC_TPB; if (b < 1) b = 1;
        sumcheck_fold<<<(unsigned)b, SMC_TPB>>>(dA, dB, dAo, dBo, half, r);
        cudaMemset(d_u0, 0, sizeof(F128)); cudaMemset(d_u2, 0, sizeof(F128));
        return;
    }
    long long out_pairs = half >> 1;
    int blocks = sumcheck_blocks(out_pairs);
    sumcheck_fold_and_message_partial<<<blocks, SMC_TPB>>>(dA, dB, dAo, dBo, out_pairs, r, d_p0, d_p2);
    combine_sumcheck_message<<<1, SMC_TPB>>>(d_p0, d_p2, blocks, d_u0, d_u2);
}

// d_part needs 8 * SMC_MAX_BLOCKS entries; d_out receives the 8 slots.
inline void launch_sumcheck_lookahead(const F128* dA, const F128* dB, F128* dAo, F128* dBo,
                                       long long out_quads, F128 r1, F128 r2,
                                       F128* d_part, F128* d_out) {
    int blocks = sumcheck_blocks(out_quads);
    sumcheck_lookahead_fold_and_message_partial<<<blocks, SMC_TPB>>>(dA, dB, dAo, dBo, out_quads, r1, r2, d_part);
    combine_sumcheck_lookahead_message<<<8, SMC_TPB>>>(d_part, blocks, d_out);
}
