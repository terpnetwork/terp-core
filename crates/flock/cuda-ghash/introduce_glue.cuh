// introduce_new + glue — step 5 of the GPU pcs::open (Ligerito) port
// for the GPU Ligerito open. Ports the α-batched basis introduction the recursive
// prover runs when a level's induced basis (step 4) enters the sumcheck
// (src/pcs/ligerito.rs SumcheckProver::introduce_new_with_eval + glue):
//
//   introduce: msg{u_0,u_2}, h_new = Σ_x f·b_new   (round_msg_and_eval_lsb)
//   glue(β):   combined_basis[j] += β·b_new[j]      (t_r += β·h_new on host)
//
// Per pair j (adjacent / LSB): f0=f[2j], f1=f[2j+1], b0=b[2j], b1=b[2j+1].
//   u_0 = Σ f0·b0;  u_2 = Σ (f0+f1)(b0+b1);  h_new = Σ (f0·b0 + f1·b1).
// Three reduce-per-term (F128) sums; glue is a pointwise AXPY. (Deferred F256
// reduction measured a wash-to-loss on this GPU — see sumcheck_ab.cuh.)
#pragma once
#include "f128.cuh"

#ifndef IGL_TPB
#define IGL_TPB 256
#endif
#ifndef IGL_MAX_BLOCKS
#define IGL_MAX_BLOCKS 2048
#endif

// Block-partial reduction → three F128 sums: a0=Σ f0·b0, a2=Σ (f0+f1)(b0+b1),
// aodd=Σ f1·b1. (h_new = a0 ^ aodd; u_0 = a0; u_2 = a2.)
__global__ void basis_message_evaluation_partial(const F128* __restrict__ F, const F128* __restrict__ B,
                                 long long half, F128* p0, F128* p2, F128* podd) {
    // Reduce-per-term (F128) rather than deferred (F256) — see sumcheck_ab.cuh.
    __shared__ F128 s0[IGL_TPB], s2[IGL_TPB], sodd[IGL_TPB];
    long long t = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    long long stride = (long long)gridDim.x * blockDim.x;
    F128 e0{0, 0}, e2{0, 0}, eodd{0, 0};
    for (long long j = t; j < half; j += stride) {
        F128 f0 = F[2 * j], f1 = F[2 * j + 1];
        F128 b0 = B[2 * j], b1 = B[2 * j + 1];
        e0 = f128_add(e0, ghash_mul_karatsuba(f0, b0));
        e2 = f128_add(e2, ghash_mul_karatsuba(f128_add(f0, f1), f128_add(b0, b1)));
        eodd = f128_add(eodd, ghash_mul_karatsuba(f1, b1));
    }
    int x = threadIdx.x;
    s0[x] = e0; s2[x] = e2; sodd[x] = eodd;
    __syncthreads();
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (x < s) { s0[x] = f128_add(s0[x], s0[x + s]); s2[x] = f128_add(s2[x], s2[x + s]); sodd[x] = f128_add(sodd[x], sodd[x + s]); }
        __syncthreads();
    }
    if (x == 0) { p0[blockIdx.x] = s0[0]; p2[blockIdx.x] = s2[0]; podd[blockIdx.x] = sodd[0]; }
}

// One 256-thread block (was a single-thread loop, ~200 us at 2048 blocks; bit-identical).
__global__ void combine_basis_message_evaluation(const F128* p0, const F128* p2, const F128* podd, int blocks,
                                 F128* u0, F128* u2, F128* h_new) {
    __shared__ F128 s0[IGL_TPB], s2[IGL_TPB], sodd[IGL_TPB];
    F128 a0{0, 0}, a2{0, 0}, aodd{0, 0};
    for (int b = threadIdx.x; b < blocks; b += blockDim.x) {
        a0 = f128_add(a0, p0[b]); a2 = f128_add(a2, p2[b]); aodd = f128_add(aodd, podd[b]);
    }
    int x = threadIdx.x;
    s0[x] = a0; s2[x] = a2; sodd[x] = aodd;
    __syncthreads();
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (x < s) { s0[x] = f128_add(s0[x], s0[x + s]); s2[x] = f128_add(s2[x], s2[x + s]);
                     sodd[x] = f128_add(sodd[x], sodd[x + s]); }
        __syncthreads();
    }
    if (x == 0) { *u0 = s0[0]; *u2 = s2[0]; *h_new = f128_add(s0[0], sodd[0]); }   // Σ f0·b0 + Σ f1·b1
}

// glue: combined_basis[j] ^= β · b_new[j]  (in place).
__global__ void combine_basis_polynomials(F128* __restrict__ cb, const F128* __restrict__ b_new,
                          F128 beta, long long n) {
    long long j = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    if (j >= n) return;
    cb[j] = f128_add(cb[j], ghash_mul_karatsuba(beta, b_new[j]));
}

inline int igl_blocks(long long half) {
    long long b = (half + IGL_TPB - 1) / IGL_TPB;
    if (b < 1) b = 1;
    if (b > IGL_MAX_BLOCKS) b = IGL_MAX_BLOCKS;
    return (int)b;
}

inline void launch_basis_message_evaluation(const F128* dF, const F128* dB, long long half,
                            F128* d_p0, F128* d_p2, F128* d_podd,
                            F128* d_u0, F128* d_u2, F128* d_hnew) {
    int blocks = igl_blocks(half);
    basis_message_evaluation_partial<<<blocks, IGL_TPB>>>(dF, dB, half, d_p0, d_p2, d_podd);
    combine_basis_message_evaluation<<<1, IGL_TPB>>>(d_p0, d_p2, d_podd, blocks, d_u0, d_u2, d_hnew);
}

inline void launch_glue(F128* d_cb, const F128* d_bnew, F128 beta, long long n, int tpb = IGL_TPB) {
    long long blocks = (n + tpb - 1) / tpb;
    combine_basis_polynomials<<<(unsigned)blocks, tpb>>>(d_cb, d_bnew, beta, n);
}
