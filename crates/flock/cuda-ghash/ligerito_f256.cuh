// The F256 Ligerito fold ladder on CUDA — port of
// crates/flock-core/src/pcs/ligerito/extension.rs::recursive_prover_with_basis_impl
// (transcript "flock-ligerito-basis-f256-split-v0", the ONLY ladder the branch
// verifier accepts). Byte-for-byte on the transcript and on every proof field.
//
// Protocol shape (m22 fast: initial_k=6, r=2, ks=[4,4]):
//   absorb label/target/L0 CAP → L0 OOD loop (β-batched into target + the
//   round-0 message + the basis, claim-PoW each) → observe round-0 message →
//   initial_k F256-challenge folds, the LAST replaced by the CODE-SWITCH
//   message → commit the split table (base-field NTT+Merkle, absorb its cap)
//   → level OODs (F128 message+eval on the split table; claim-PoW β glue) →
//   L0 query phase (query-PoW + ONE stratified vec squeeze; consistency-PoW
//   α; capped per-query paths) → induce basis → presplit introduce + claim-PoW
//   glue → per recursive level: k folds (+switch unless final) / commit /
//   OODs / query phase / induce / introduce — final level ships yr =
//   split_coordinates(f) in the clear and opens the last tree.
//
// Field/state representation: F256Ext{c0,c1} arrays reinterpret in place as
// the split base-field word list, so a code switch on `f` is a POINTER CAST;
// only the basis split materializes ((B, u·B) pairs). Post-switch tables are
// F128 arrays (base-valued); a level's first fold returns them to F256.
//
// The four big ping-pong regions are each `len·16` bytes: fold 0's F256
// output (half the count, twice the width) exactly fills one region, and
// every later state is smaller — same peak as the old F128 ladder.
#pragma once
#include <vector>
#include <cstdint>
#include <cstdio>
#include <algorithm>
#include <map>
#include "f128.cuh"
#include "ntt_host.hpp"
#include "ntt_f128.cuh"
#include "merkle.cuh"
#include "merkle_open.hpp"
#include "merkle_open_device.cuh"
#include "induce_sumcheck.cuh"   // build_eq_device
#include "introduce_glue.cuh"    // launch_basis_message_evaluation, launch_glue
#include "sumcheck_ab.cuh"       // combine_sumcheck_message (F128 partial combine)
#include "ntt_transpose.cuh"     // scatter_query_weights, launch_transpose_ntt, clear_field_elements
#include "f256.cuh"
#include "challenger.hpp"

#ifndef LF_TPB
#define LF_TPB 256
#endif
#ifndef LF_MAX_BLOCKS
#define LF_MAX_BLOCKS 2048
#endif

// ---- kernels ---------------------------------------------------------------

// fold_step_base for BOTH arrays: out[j] = from(in[2j]) + r·(in[2j]+in[2j+1]).
// r·x for base x is (r0·x, r1·x) — 2 muls per element per array.
__global__ void lf_fold_base_pair(const F128* __restrict__ A, const F128* __restrict__ B,
                                  F256Ext* __restrict__ Ao, F256Ext* __restrict__ Bo,
                                  long long half, F256Ext r) {
    long long j = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    if (j >= half) return;
    F128 xa = f128_add(A[2 * j], A[2 * j + 1]);
    F128 xb = f128_add(B[2 * j], B[2 * j + 1]);
    Ao[j] = F256Ext{f128_add(A[2 * j], ghash_mul_karatsuba(r.c0, xa)), ghash_mul_karatsuba(r.c1, xa)};
    Bo[j] = F256Ext{f128_add(B[2 * j], ghash_mul_karatsuba(r.c0, xb)), ghash_mul_karatsuba(r.c1, xb)};
}

// fold_step_ext for both arrays: out[j] = in[2j] + r·(in[2j]+in[2j+1]).
__global__ void lf_fold_ext_pair(const F256Ext* __restrict__ A, const F256Ext* __restrict__ B,
                                 F256Ext* __restrict__ Ao, F256Ext* __restrict__ Bo,
                                 long long half, F256Ext r) {
    long long j = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    if (j >= half) return;
    Ao[j] = f256x_add(A[2 * j], f256x_mul(r, f256x_add(A[2 * j], A[2 * j + 1])));
    Bo[j] = f256x_add(B[2 * j], f256x_mul(r, f256x_add(B[2 * j], B[2 * j + 1])));
}

// A recursive level's FIRST fold: the f-side is the just-split base table
// (F128 words — fold_step_split_base, 2 muls), the b-side is generic F256.
__global__ void lf_fold_switch_pair(const F128* __restrict__ A, const F256Ext* __restrict__ B,
                                    F256Ext* __restrict__ Ao, F256Ext* __restrict__ Bo,
                                    long long half, F256Ext r) {
    long long j = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    if (j >= half) return;
    F128 xa = f128_add(A[2 * j], A[2 * j + 1]);
    Ao[j] = F256Ext{f128_add(A[2 * j], ghash_mul_karatsuba(r.c0, xa)), ghash_mul_karatsuba(r.c1, xa)};
    Bo[j] = f256x_add(B[2 * j], f256x_mul(r, f256x_add(B[2 * j], B[2 * j + 1])));
}

// round_msg over F256 arrays (adjacent pairing):
//   u_0 = Σ_j f[2j]·b[2j],  u_2 = Σ_j (f[2j]+f[2j+1])·(b[2j]+b[2j+1]).
// Block partials in (p0, p2); XOR reduction order is irrelevant in char 2.
__global__ void lf_msg_partial(const F256Ext* __restrict__ A, const F256Ext* __restrict__ B,
                               long long half, F256Ext* p0, F256Ext* p2) {
    __shared__ F256Ext s0[LF_TPB];
    __shared__ F256Ext s2[LF_TPB];
    long long t = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    long long stride = (long long)gridDim.x * blockDim.x;
    F256Ext e0 = f256x_zero(), e2 = f256x_zero();
    for (long long j = t; j < half; j += stride) {
        F256Ext a0 = A[2 * j], a1 = A[2 * j + 1];
        F256Ext b0 = B[2 * j], b1 = B[2 * j + 1];
        e0 = f256x_add(e0, f256x_mul(a0, b0));
        e2 = f256x_add(e2, f256x_mul(f256x_add(a0, a1), f256x_add(b0, b1)));
    }
    int x = threadIdx.x;
    s0[x] = e0; s2[x] = e2;
    __syncthreads();
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (x < s) { s0[x] = f256x_add(s0[x], s0[x + s]); s2[x] = f256x_add(s2[x], s2[x + s]); }
        __syncthreads();
    }
    if (x == 0) { p0[blockIdx.x] = s0[0]; p2[blockIdx.x] = s2[0]; }
}

// round_msg_fbase: the code-switch replacement message. f is the SPLIT table
// (base F128 words, length 2·half), b the split basis (F256, length 2·half):
//   u_0 = Σ_j b[2j]·f[2j],  u_2 = Σ_j (b[2j]+b[2j+1])·(f[2j]+f[2j+1]).
__global__ void lf_msg_fbase_partial(const F128* __restrict__ A, const F256Ext* __restrict__ B,
                                     long long half, F256Ext* p0, F256Ext* p2) {
    __shared__ F256Ext s0[LF_TPB];
    __shared__ F256Ext s2[LF_TPB];
    long long t = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    long long stride = (long long)gridDim.x * blockDim.x;
    F256Ext e0 = f256x_zero(), e2 = f256x_zero();
    for (long long j = t; j < half; j += stride) {
        F128 f0 = A[2 * j], f1 = A[2 * j + 1];
        F256Ext b0 = B[2 * j], b1 = B[2 * j + 1];
        e0 = f256x_add(e0, f256x_mul_base(b0, f0));
        e2 = f256x_add(e2, f256x_mul_base(f256x_add(b0, b1), f128_add(f0, f1)));
    }
    int x = threadIdx.x;
    s0[x] = e0; s2[x] = e2;
    __syncthreads();
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (x < s) { s0[x] = f256x_add(s0[x], s0[x + s]); s2[x] = f256x_add(s2[x], s2[x + s]); }
        __syncthreads();
    }
    if (x == 0) { p0[blockIdx.x] = s0[0]; p2[blockIdx.x] = s2[0]; }
}

__global__ void lf_msg_combine(const F256Ext* p0, const F256Ext* p2, int blocks, F256Ext* out2) {
    __shared__ F256Ext s0[LF_TPB];
    __shared__ F256Ext s2[LF_TPB];
    F256Ext a0 = f256x_zero(), a2 = f256x_zero();
    for (int b = threadIdx.x; b < blocks; b += blockDim.x) {
        a0 = f256x_add(a0, p0[b]);
        a2 = f256x_add(a2, p2[b]);
    }
    int x = threadIdx.x;
    s0[x] = a0; s2[x] = a2;
    __syncthreads();
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (x < s) { s0[x] = f256x_add(s0[x], s0[x + s]); s2[x] = f256x_add(s2[x], s2[x + s]); }
        __syncthreads();
    }
    if (x == 0) { out2[0] = s0[0]; out2[1] = s2[0]; }
}

// split_basis: out[2j] = B[j], out[2j+1] = u·B[j]  (u·B = (x⁻¹·b1, b0+b1)).
__global__ void lf_split_basis(const F256Ext* __restrict__ B, F256Ext* __restrict__ out,
                               long long n) {
    long long j = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    if (j >= n) return;
    F256Ext b = B[j];
    out[2 * j] = b;
    out[2 * j + 1] = f256x_mul_by_u(b);
}

// The presplit introduce message's TWO base sums over (split table, induced
// F128 basis): m0 = Σ_j f[2j]·B[j], m2 = Σ_j (f[2j]+f[2j+1])·B[j].
// (introduce_presplit_basis: basis pairs are ((B,0),(0,B)), so the F256
// message is u_0 = (m0, 0), u_2 = (m2, m2) — assembled on the host.)
__global__ void lf_presplit_msg_partial(const F128* __restrict__ F, const F128* __restrict__ B,
                                        long long n, F128* p0, F128* p2) {
    __shared__ F128 s0[LF_TPB];
    __shared__ F128 s2[LF_TPB];
    long long t = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    long long stride = (long long)gridDim.x * blockDim.x;
    F128 e0{0, 0}, e2{0, 0};
    for (long long j = t; j < n; j += stride) {
        F128 f0 = F[2 * j], f1 = F[2 * j + 1], b = B[j];
        e0 = f128_add(e0, ghash_mul_karatsuba(f0, b));
        e2 = f128_add(e2, ghash_mul_karatsuba(f128_add(f0, f1), b));
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

// OOD glue onto an F256 basis: b[i].c0 += β·basis[i] (base-valued introduce —
// the u-limbs are untouched).
__global__ void lf_glue_base(F256Ext* __restrict__ b, const F128* __restrict__ basis,
                             F128 beta, long long n) {
    long long i = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    b[i].c0 = f128_add(b[i].c0, ghash_mul_karatsuba(beta, basis[i]));
}

// Presplit glue: split_basis(lifted B)·β = ((β·B, 0), (0, β·B)) pairs, so
// b[2j].c0 += β·B[j] and b[2j+1].c1 += β·B[j].
__global__ void lf_glue_presplit(F256Ext* __restrict__ b, const F128* __restrict__ basis,
                                 F128 beta, long long n) {
    long long j = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    if (j >= n) return;
    F128 w = ghash_mul_karatsuba(beta, basis[j]);
    b[2 * j].c0 = f128_add(b[2 * j].c0, w);
    b[2 * j + 1].c1 = f128_add(b[2 * j + 1].c1, w);
}

// replicate-fill for the recursive commits (the fused src read diverges from
// the Rust commit at small layer counts — recursive codewords always take
// the replicate path; see prove_ffi.cu's L0 note).
__global__ void lf_replicate_message(const F128* __restrict__ msg, F128* __restrict__ cw,
                                     long long cw_len, long long msg_len) {
    long long i = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= cw_len) return;
    cw[i] = msg[i % msg_len];
}

__global__ void lf_gather_rows(const F128* __restrict__ codeword,
                               const unsigned long long* __restrict__ positions,
                               int n_rows, int row_len, F128* __restrict__ rows) {
    long long i = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    long long n = (long long)n_rows * row_len;
    if (i >= n) return;
    int row = (int)(i / row_len);
    int col = (int)(i % row_len);
    rows[i] = codeword[positions[row] * row_len + col];
}

// ---- host driver -----------------------------------------------------------

struct LigAlloc {
    cudaError_t (*alloc)(void** p, size_t bytes);
    cudaError_t (*release)(void* p);
};

inline cudaError_t lf_cuda_alloc(void** p, size_t bytes) { return cudaMalloc(p, bytes); }
inline cudaError_t lf_cuda_release(void* p) { return cudaFree(p); }
inline LigAlloc lig_default_alloc() { return LigAlloc{lf_cuda_alloc, lf_cuda_release}; }

struct LigMsg256 {
    F256Ext u0, u2;
};

struct LigLevelOpen {
    std::vector<F128> rows_flat;
    size_t n_rows = 0, row_len = 0;
    std::vector<MHash> path;   // capped per-query siblings, sample order
};

struct LigF256Proof {
    std::vector<MHash> initial_cap;
    std::vector<std::vector<MHash>> recursive_caps;   // levels 1..r
    LigLevelOpen initial_open;                        // L0 tree
    std::vector<LigLevelOpen> recursive_opens;        // trees 1..r-1
    LigLevelOpen final_open;                          // tree r
    std::vector<F128> yr;                             // split coordinates, in the clear
    std::vector<LigMsg256> transcript;                // sumcheck_transcript_f256, push order
    std::vector<F128> ood_values;
    std::vector<uint64_t> grinding_nonces;            // query-phase PoW, one per level
    std::vector<uint64_t> claim_batch_nonces;
    std::vector<uint64_t> consistency_batch_nonces;
};

struct LigF256Config {
    int log_n;
    int initial_k;
    int recursive_steps;
    const int* log_inv_rates;                     // [r+1]
    const int* recursive_ks;                      // [r]
    const int* queries;                           // [r+1]
    const int* grinding_bits;                     // [r+1]
    const int* claim_batch_grinding_bits;         // [r+1]
    const int* consistency_batch_grinding_bits;   // [r+1]
    const int* ood_samples;                       // [r+1]
};

inline ChF128 lf_toch(F128 x) { return ChF128{x.lo, x.hi}; }
inline F128 lf_frch(ChF128 x) { return F128{x.lo, x.hi}; }
inline F256Ext lf_frch256(ChF256 x) { return F256Ext{lf_frch(x.c0), lf_frch(x.c1)}; }

inline int lf_ceil_log2(size_t n) {
    int c = 0;
    while (((size_t)1 << c) < n) c++;
    return c;
}

// build_eq_table on host (lincheck.rs convention: t[i+len] = t[i]·r_j,
// t[i] = t[i]·(1+r_j)) — for the α query weights, which must be duplicate-
// combined host-side before the device scatter.
inline std::vector<F128> lf_build_eq_host(const std::vector<F128>& r) {
    std::vector<F128> t;
    t.reserve((size_t)1 << r.size());
    t.push_back(F128{1ull, 0ull});
    for (F128 rj : r) {
        F128 opr = f128_add_hd(F128{1ull, 0ull}, rj);
        size_t len = t.size();
        t.resize(2 * len);
        for (size_t x = 0; x < len; x++) {
            F128 v = t[x];
            t[x + len] = f128_mul_hd(v, rj);
            t[x] = f128_mul_hd(v, opr);
        }
    }
    return t;
}

#define LFCK(x) do { cudaError_t e = (x); if (e != cudaSuccess) { \
    printf("ligerito_f256 CUDA error %s at %s:%d\n", cudaGetErrorString(e), __FILE__, __LINE__); \
    return 200; } } while (0)

// Persistent twiddle cache for the (small) recursive commits.
inline cudaError_t lf_get_twiddles(int k_code, const TwiddleTable*& host, F128*& device) {
    static std::map<int, std::pair<TwiddleTable, F128*>> cache;
    auto found = cache.find(k_code);
    if (found == cache.end()) {
        TwiddleTable tt = build_twiddle_table(k_code);
        F128* d = nullptr;
        cudaError_t err = cudaMalloc(&d, tt.data.size() * sizeof(F128));
        if (err != cudaSuccess) return err;
        err = cudaMemcpy(d, tt.data.data(), tt.data.size() * sizeof(F128), cudaMemcpyHostToDevice);
        if (err != cudaSuccess) return err;
        found = cache.emplace(k_code, std::make_pair(std::move(tt), d)).first;
    }
    host = &found->second.first;
    device = found->second.second;
    return cudaSuccess;
}

// Observe one ladder message and append it to the running transcript.
inline void lf_observe_msg(FsChallenger& ch, std::vector<LigMsg256>& transcript, LigMsg256 m) {
    ch.observe_f256(ChF256{lf_toch(m.u0.c0), lf_toch(m.u0.c1)});
    ch.observe_f256(ChF256{lf_toch(m.u2.c0), lf_toch(m.u2.c1)});
    transcript.push_back(m);
}

// Run the complete F256 ladder. `d_f`/`d_b` are the packed witness and the
// γ-combined basis (each 2^log_n F128, device) — CONSUMED as fold scratch.
// `first_u0/u2` is the round-0 message over (f, b) (the caller's combine
// pass); the L0 OOD loop folds into it here, as the Rust driver does. The
// challenger must sit exactly where the Rust caller's does (pre-label).
// The L0 codeword/tree stay caller-owned.
inline int run_ligerito_f256(const LigF256Config& C, FsChallenger& ch, F128 target,
                             F128 first_u0, F128 first_u2,
                             F128* d_f, F128* d_b,
                             const F128* d_l0_codeword, const uint8_t* d_l0_tree,
                             long long l0_block_len, int l0_num_lanes,
                             const LigAlloc& A, LigF256Proof& out) {
    const int log_n = C.log_n, initial_k = C.initial_k, r = C.recursive_steps;
    const long long len = 1LL << log_n;
    const int n1 = log_n - initial_k;
    const int d0 = lf_ceil_log2((size_t)l0_block_len);

    // Per-level stratified schedules (LevelSchedule::decompose — the same
    // rule with_default_stratified stores on the Rust config).
    std::vector<std::vector<uint32_t>> depths(r + 1);
    std::vector<uint32_t> caps(r + 1);
    {
        // level block logs: d0, then per commit level its k_code.
        int dim = n1 + 1;
        depths[0] = stratified_depths((size_t)C.queries[0], (uint32_t)d0);
        caps[0] = stratified_cap_depth(depths[0]);
        for (int lvl = 1; lvl <= r; lvl++) {
            int log_lanes = C.recursive_ks[lvl - 1];
            int log_cols = dim - log_lanes;
            int dlvl = log_cols + C.log_inv_rates[lvl];
            depths[lvl] = stratified_depths((size_t)C.queries[lvl], (uint32_t)dlvl);
            caps[lvl] = stratified_cap_depth(depths[lvl]);
            dim = log_cols + 1;   // next level's split dim (k−1 vars removed + coord bit)
        }
    }

    static const uint8_t LABEL[] = "flock-ligerito-basis-f256-split-v0";
    ch.observe_label(LABEL, sizeof(LABEL) - 1);
    ch.observe_f128(lf_toch(target));
    out.initial_cap = merkle_cap_layer_device(d_l0_tree, (size_t)l0_block_len, caps[0]);
    ch.observe_bytes((const uint8_t*)out.initial_cap.data(), out.initial_cap.size() * 32);

    // Scratch for messages/evals.
    F256Ext *d_p256_0, *d_p256_2, *d_out256;
    F128 *d_p0, *d_p2, *d_podd, *d_u0, *d_u2, *d_hnew;
    LFCK(A.alloc((void**)&d_p256_0, LF_MAX_BLOCKS * sizeof(F256Ext)));
    LFCK(A.alloc((void**)&d_p256_2, LF_MAX_BLOCKS * sizeof(F256Ext)));
    LFCK(A.alloc((void**)&d_out256, 2 * sizeof(F256Ext)));
    LFCK(A.alloc((void**)&d_p0, LF_MAX_BLOCKS * sizeof(F128)));
    LFCK(A.alloc((void**)&d_p2, LF_MAX_BLOCKS * sizeof(F128)));
    LFCK(A.alloc((void**)&d_podd, LF_MAX_BLOCKS * sizeof(F128)));
    LFCK(A.alloc((void**)&d_u0, sizeof(F128)));
    LFCK(A.alloc((void**)&d_u2, sizeof(F128)));
    LFCK(A.alloc((void**)&d_hnew, sizeof(F128)));

    auto lf_blocks = [](long long items) {
        long long b = (items + LF_TPB - 1) / LF_TPB;
        if (b < 1) b = 1;
        if (b > LF_MAX_BLOCKS) b = LF_MAX_BLOCKS;
        return (int)b;
    };
    // F256 message over folded arrays of F256 length `n` (pairs = n/2).
    auto msg256 = [&](const F256Ext* fa, const F256Ext* fb, long long n) -> LigMsg256 {
        long long half = n / 2;
        int blocks = lf_blocks(half);
        lf_msg_partial<<<blocks, LF_TPB>>>(fa, fb, half, d_p256_0, d_p256_2);
        lf_msg_combine<<<1, LF_TPB>>>(d_p256_0, d_p256_2, blocks, d_out256);
        F256Ext h[2];
        cudaMemcpy(h, d_out256, sizeof(h), cudaMemcpyDeviceToHost);
        return LigMsg256{h[0], h[1]};
    };
    // Code-switch replacement message over (split F128 table of 2·half words,
    // split F256 basis of 2·half).
    auto msg_fbase = [&](const F128* fa, const F256Ext* fb, long long half) -> LigMsg256 {
        int blocks = lf_blocks(half);
        lf_msg_fbase_partial<<<blocks, LF_TPB>>>(fa, fb, half, d_p256_0, d_p256_2);
        lf_msg_combine<<<1, LF_TPB>>>(d_p256_0, d_p256_2, blocks, d_out256);
        F256Ext h[2];
        cudaMemcpy(h, d_out256, sizeof(h), cudaMemcpyDeviceToHost);
        return LigMsg256{h[0], h[1]};
    };

    // ---- L0 OOD loop (β-batched into target / round-0 message / basis) ----
    {
        F128* d_eq;
        LFCK(A.alloc((void**)&d_eq, (size_t)len * sizeof(F128)));
        for (int o = 0; o < C.ood_samples[0]; o++) {
            std::vector<ChF128> z(log_n);
            ch.sample_f128_vec(z.data(), log_n);
            std::vector<F128> zf(log_n);
            for (int i = 0; i < log_n; i++) zf[i] = lf_frch(z[i]);
            build_eq_device(d_eq, zf.data(), log_n);
            launch_basis_message_evaluation(d_f, d_eq, len / 2, d_p0, d_p2, d_podd, d_u0, d_u2, d_hnew);
            LFCK(cudaGetLastError());
            F128 ou0, ou2, y;
            LFCK(cudaMemcpy(&ou0, d_u0, sizeof(F128), cudaMemcpyDeviceToHost));
            LFCK(cudaMemcpy(&ou2, d_u2, sizeof(F128), cudaMemcpyDeviceToHost));
            LFCK(cudaMemcpy(&y, d_hnew, sizeof(F128), cudaMemcpyDeviceToHost));
            ch.observe_f128(lf_toch(y));
            out.ood_values.push_back(y);
            ChF128 beta_c;
            out.claim_batch_nonces.push_back(
                ch.grind_pow_and_sample_f128((uint32_t)C.claim_batch_grinding_bits[0], &beta_c));
            F128 beta = lf_frch(beta_c);
            target = f128_add_hd(target, f128_mul_hd(beta, y));
            first_u0 = f128_add_hd(first_u0, f128_mul_hd(beta, ou0));
            first_u2 = f128_add_hd(first_u2, f128_mul_hd(beta, ou2));
            launch_glue(d_b, d_eq, beta, len);
            LFCK(cudaGetLastError());
        }
        LFCK(A.release(d_eq));
    }
    (void)target;   // consumed: its post-OOD value never re-enters the transcript

    // ---- round-0 message ----
    lf_observe_msg(ch, out.transcript,
                   LigMsg256{f256x_from_base(first_u0), f256x_from_base(first_u2)});

    // ---- ping-pong regions (each len·16 bytes) ----
    void* regions[4] = {d_f, d_b, nullptr, nullptr};
    LFCK(A.alloc(&regions[2], (size_t)len * sizeof(F128)));
    LFCK(A.alloc(&regions[3], (size_t)len * sizeof(F128)));
    int cur_f = 0, cur_b = 1;   // region indices of the live state (F128 to start)
    auto two_free = [&](int& a, int& b) {
        a = -1; b = -1;
        for (int i = 0; i < 4; i++)
            if (i != cur_f && i != cur_b) { if (a < 0) a = i; else b = i; }
    };

    // ---- initial_k folds + code switch ----
    long long n256 = 0;                 // current F256 element count
    const F128* fa_split = nullptr;     // post-switch split table (F128 view)
    long long split_words = 0;          // its word count = 2^current_split_dim
    for (int j = 0; j < initial_k; j++) {
        F256Ext r256 = lf_frch256(ch.sample_f256());
        int oa, ob;
        two_free(oa, ob);
        if (j == 0) {
            long long half = len / 2;
            lf_fold_base_pair<<<(unsigned)((half + LF_TPB - 1) / LF_TPB), LF_TPB>>>(
                d_f, d_b, (F256Ext*)regions[oa], (F256Ext*)regions[ob], half, r256);
            n256 = half;
        } else {
            long long half = n256 / 2;
            lf_fold_ext_pair<<<(unsigned)((half + LF_TPB - 1) / LF_TPB), LF_TPB>>>(
                (const F256Ext*)regions[cur_f], (const F256Ext*)regions[cur_b],
                (F256Ext*)regions[oa], (F256Ext*)regions[ob], half, r256);
            n256 = half;
        }
        LFCK(cudaGetLastError());
        cur_f = oa; cur_b = ob;
        LigMsg256 msg;
        if (j + 1 == initial_k) {
            // Code switch: the F256 f-array IS the split F128 table; the
            // basis splits into (B, u·B) pairs in a free region.
            fa_split = (const F128*)regions[cur_f];
            split_words = 2 * n256;
            int sa, sb;
            two_free(sa, sb);
            (void)sb;
            lf_split_basis<<<(unsigned)((n256 + LF_TPB - 1) / LF_TPB), LF_TPB>>>(
                (const F256Ext*)regions[cur_b], (F256Ext*)regions[sa], n256);
            LFCK(cudaGetLastError());
            cur_b = sa;
            msg = msg_fbase(fa_split, (const F256Ext*)regions[cur_b], n256);
        } else {
            msg = msg256((const F256Ext*)regions[cur_f], (const F256Ext*)regions[cur_b], n256);
        }
        lf_observe_msg(ch, out.transcript, msg);
    }

    int current_split_dim = n1 + 1;

    // ---- per-level state: the previously committed tree we open next ----
    const F128* d_prev_cw = d_l0_codeword;
    const uint8_t* d_prev_tree = d_l0_tree;
    long long prev_bl = l0_block_len;
    int prev_lanes = l0_num_lanes;
    bool prev_owned = false;   // L0 is caller-owned
    F128* d_prev_cw_owned = nullptr;
    uint8_t* d_prev_tree_owned = nullptr;

    // Induce scratch, sized for the LARGEST opened block across levels (L0 in
    // every shipped ladder, but derived rather than assumed).
    F128 *d_ind_basis, *d_ind_alpha;
    unsigned long long* d_ind_q;
    size_t max_q = 0, max_al = 1, max_block = (size_t)l0_block_len;
    {
        int dim = n1 + 1;
        for (int lvl = 1; lvl <= r; lvl++) {
            int log_cols = dim - C.recursive_ks[lvl - 1];
            max_block = std::max(max_block, (size_t)1 << (log_cols + C.log_inv_rates[lvl]));
            dim = log_cols + 1;
        }
        for (int l = 0; l <= r; l++) {
            max_q = std::max(max_q, (size_t)C.queries[l]);
            max_al = std::max(max_al, (size_t)1 << lf_ceil_log2((size_t)C.queries[l]));
        }
    }
    LFCK(A.alloc((void**)&d_ind_basis, max_block * sizeof(F128)));
    LFCK(A.alloc((void**)&d_ind_alpha, max_al * sizeof(F128)));
    LFCK(A.alloc((void**)&d_ind_q, max_q * sizeof(unsigned long long)));

    F128* d_eq2;   // level-OOD eq tables (≤ 2^current_split_dim)
    LFCK(A.alloc((void**)&d_eq2, ((size_t)1 << current_split_dim) * sizeof(F128)));

    // Commit the current split table for `level` (log_lanes = recursive_ks
    // [level-1], rate = log_inv_rates[level]), absorb its cap.
    auto commit_level = [&](int level, F128*& d_cw_out, uint8_t*& d_tree_out,
                            long long& bl_out, int& lanes_out) -> int {
        int log_lanes = C.recursive_ks[level - 1];
        int log_cols = current_split_dim - log_lanes;
        int rate = C.log_inv_rates[level];
        int k_code = log_cols + rate;
        int num_ntts = 1 << log_lanes;
        long long bl = 1LL << k_code;
        long long cw_len = bl * num_ntts;
        const TwiddleTable* tt;
        F128* d_tw;
        LFCK(lf_get_twiddles(k_code, tt, d_tw));
        LFCK(A.alloc((void**)&d_cw_out, (size_t)cw_len * sizeof(F128)));
        LFCK(A.alloc((void**)&d_tree_out, (size_t)(2 * bl - 1) * 32));
        lf_replicate_message<<<(unsigned)((cw_len + LF_TPB - 1) / LF_TPB), LF_TPB>>>(
            fa_split, d_cw_out, cw_len, split_words);
        LFCK(cudaGetLastError());
        launch_ntt(d_cw_out, d_tw, *tt, rate, k_code, num_ntts);
        LFCK(cudaGetLastError());
        launch_merkle((const uint8_t*)d_cw_out, d_tree_out, bl, num_ntts * 16);
        LFCK(cudaDeviceSynchronize());
        bl_out = bl;
        lanes_out = num_ntts;
        std::vector<MHash> cap = merkle_cap_layer_device(d_tree_out, (size_t)bl, caps[level]);
        ch.observe_bytes((const uint8_t*)cap.data(), cap.size() * 32);
        out.recursive_caps.push_back(std::move(cap));
        return 0;
    };

    // Level OODs on the split table (base-valued): F128 message + eval, then
    // claim-PoW β glue onto the basis c0 limbs.
    auto level_oods = [&](int level) -> int {
        for (int o = 0; o < C.ood_samples[level]; o++) {
            std::vector<ChF128> z(current_split_dim);
            ch.sample_f128_vec(z.data(), current_split_dim);
            std::vector<F128> zf(current_split_dim);
            for (int i = 0; i < current_split_dim; i++) zf[i] = lf_frch(z[i]);
            build_eq_device(d_eq2, zf.data(), current_split_dim);
            launch_basis_message_evaluation(fa_split, d_eq2, split_words / 2, d_p0, d_p2, d_podd,
                                            d_u0, d_u2, d_hnew);
            LFCK(cudaGetLastError());
            F128 mu0, mu2, y;
            LFCK(cudaMemcpy(&mu0, d_u0, sizeof(F128), cudaMemcpyDeviceToHost));
            LFCK(cudaMemcpy(&mu2, d_u2, sizeof(F128), cudaMemcpyDeviceToHost));
            LFCK(cudaMemcpy(&y, d_hnew, sizeof(F128), cudaMemcpyDeviceToHost));
            ch.observe_f128(lf_toch(y));
            out.ood_values.push_back(y);
            lf_observe_msg(ch, out.transcript,
                           LigMsg256{f256x_from_base(mu0), f256x_from_base(mu2)});
            ChF128 beta_c;
            out.claim_batch_nonces.push_back(
                ch.grind_pow_and_sample_f128((uint32_t)C.claim_batch_grinding_bits[level], &beta_c));
            lf_glue_base<<<(unsigned)((split_words + LF_TPB - 1) / LF_TPB), LF_TPB>>>(
                (F256Ext*)regions[cur_b], d_eq2, lf_frch(beta_c), split_words);
            LFCK(cudaGetLastError());
        }
        return 0;
    };

    // Query phase against the previous tree (`open_level` indexes queries,
    // grinding, and the α consistency batch — each level grinds its OWN
    // consistency bits). Gathers rows + capped paths into `open`; returns α
    // (empty at the final level, where the squeeze happens but the α is
    // unused).
    auto query_phase = [&](int open_level, LigLevelOpen& open,
                           std::vector<F128>& alpha_out, std::vector<size_t>& q_out) -> int {
        q_out.clear();
        out.grinding_nonces.push_back(grind_and_sample_stratified_queries(
            ch, (uint32_t)C.grinding_bits[open_level], (uint32_t)lf_ceil_log2((size_t)prev_bl),
            (size_t)C.queries[open_level], depths[open_level], q_out));
        int al = lf_ceil_log2((size_t)C.queries[open_level]);
        std::vector<ChF128> alpha_c(al);
        out.consistency_batch_nonces.push_back(ch.grind_pow_and_sample_f128_vec(
            (uint32_t)C.consistency_batch_grinding_bits[open_level], alpha_c.data(), al));
        alpha_out.resize(al);
        for (int i = 0; i < al; i++) alpha_out[i] = lf_frch(alpha_c[i]);

        open.n_rows = q_out.size();
        open.row_len = prev_lanes;
        open.rows_flat.resize(open.n_rows * open.row_len);
        {
            std::vector<unsigned long long> qull(q_out.begin(), q_out.end());
            LFCK(cudaMemcpy(d_ind_q, qull.data(), qull.size() * sizeof(unsigned long long),
                            cudaMemcpyHostToDevice));
            F128* d_rows;
            LFCK(A.alloc((void**)&d_rows, open.rows_flat.size() * sizeof(F128)));
            lf_gather_rows<<<(unsigned)((open.rows_flat.size() + LF_TPB - 1) / LF_TPB), LF_TPB>>>(
                d_prev_cw, d_ind_q, (int)open.n_rows, (int)open.row_len, d_rows);
            LFCK(cudaGetLastError());
            LFCK(cudaMemcpy(open.rows_flat.data(), d_rows, open.rows_flat.size() * sizeof(F128),
                            cudaMemcpyDeviceToHost));
            LFCK(A.release(d_rows));
        }
        open.path = merkle_capped_paths_device(d_prev_tree, (size_t)prev_bl, q_out,
                                               caps[open_level]);
        return 0;
    };

    // Induce the F128 basis over the just-opened level's message domain
    // (scatter α-weights at the queries, transpose-NTT — the empty-rows
    // induce_sumcheck_poly_auto fast path), then the presplit introduce +
    // claim-PoW glue. `ext_dim` = log of the induced basis length.
    auto induce_introduce_glue = [&](int ext_dim, int next_level,
                                     const std::vector<size_t>& queries,
                                     const std::vector<F128>& alpha) -> int {
        // The i-th query weighs eq(α)[i]; a position hit by MULTIPLE queries
        // (possible across stratified summands) accumulates in char 2
        // (induce's `data[p] += v`) — combine host-side, then scatter the
        // now-distinct positions.
        std::vector<F128> wts = lf_build_eq_host(alpha);
        std::map<size_t, F128> acc;
        for (size_t i = 0; i < queries.size(); i++) {
            auto ins = acc.emplace(queries[i], wts[i]);
            if (!ins.second) ins.first->second = f128_add_hd(ins.first->second, wts[i]);
        }
        std::vector<unsigned long long> qull;
        std::vector<F128> wcomb;
        qull.reserve(acc.size());
        wcomb.reserve(acc.size());
        for (const auto& kv : acc) {
            qull.push_back((unsigned long long)kv.first);
            wcomb.push_back(kv.second);
        }
        LFCK(cudaMemcpy(d_ind_q, qull.data(), qull.size() * sizeof(unsigned long long),
                        cudaMemcpyHostToDevice));
        LFCK(cudaMemcpy(d_ind_alpha, wcomb.data(), wcomb.size() * sizeof(F128),
                        cudaMemcpyHostToDevice));
        int log_block = lf_ceil_log2((size_t)prev_bl);
        const TwiddleTable* tt;
        F128* d_tw;
        LFCK(lf_get_twiddles(log_block, tt, d_tw));
        clear_field_elements<<<(unsigned)((prev_bl + LF_TPB - 1) / LF_TPB), LF_TPB>>>(d_ind_basis,
                                                                                     prev_bl);
        scatter_query_weights<<<(unsigned)((qull.size() + LF_TPB - 1) / LF_TPB), LF_TPB>>>(
            d_ind_basis, d_ind_q, d_ind_alpha, (int)qull.size());
        launch_transpose_ntt(d_ind_basis, d_tw, *tt, log_block);
        LFCK(cudaGetLastError());
        // presplit message: pairs over the split table vs the induced basis.
        long long pairs = 1LL << ext_dim;
        int blocks = lf_blocks(pairs);
        lf_presplit_msg_partial<<<blocks, LF_TPB>>>(fa_split, d_ind_basis, pairs, d_p0, d_p2);
        combine_sumcheck_message<<<1, LF_TPB>>>(d_p0, d_p2, blocks, d_u0, d_u2);
        LFCK(cudaGetLastError());
        F128 m0, m2;
        LFCK(cudaMemcpy(&m0, d_u0, sizeof(F128), cudaMemcpyDeviceToHost));
        LFCK(cudaMemcpy(&m2, d_u2, sizeof(F128), cudaMemcpyDeviceToHost));
        lf_observe_msg(ch, out.transcript,
                       LigMsg256{f256x_from_base(m0), F256Ext{m2, m2}});
        ChF128 beta_c;
        out.claim_batch_nonces.push_back(
            ch.grind_pow_and_sample_f128((uint32_t)C.claim_batch_grinding_bits[next_level], &beta_c));
        lf_glue_presplit<<<(unsigned)((pairs + LF_TPB - 1) / LF_TPB), LF_TPB>>>(
            (F256Ext*)regions[cur_b], d_ind_basis, lf_frch(beta_c), pairs);
        LFCK(cudaGetLastError());
        return 0;
    };

    auto retire_prev = [&]() {
        if (prev_owned) {
            A.release(d_prev_cw_owned);
            A.release(d_prev_tree_owned);
        }
        prev_owned = false;
    };

    // ---- pre-loop: commit level 1, its OODs, the L0 query phase, induce ----
    {
        F128* d_cw1;
        uint8_t* d_tree1;
        long long bl1;
        int lanes1;
        int rc = commit_level(1, d_cw1, d_tree1, bl1, lanes1);
        if (rc) return rc;
        rc = level_oods(1);
        if (rc) return rc;
        std::vector<F128> alpha;
        std::vector<size_t> queries;
        rc = query_phase(0, out.initial_open, alpha, queries);
        if (rc) return rc;
        rc = induce_introduce_glue(n1, 1, queries, alpha);
        if (rc) return rc;
        d_prev_cw = d_cw1;
        d_prev_tree = d_tree1;
        prev_bl = bl1;
        prev_lanes = lanes1;
        prev_owned = true;
        d_prev_cw_owned = d_cw1;
        d_prev_tree_owned = d_tree1;
    }

    // ---- recursive levels ----
    for (int i = 0; i < r; i++) {
        int k = C.recursive_ks[i];
        for (int j = 0; j < k; j++) {
            F256Ext r256 = lf_frch256(ch.sample_f256());
            int oa, ob;
            two_free(oa, ob);
            if (j == 0) {
                long long half = split_words / 2;
                lf_fold_switch_pair<<<(unsigned)((half + LF_TPB - 1) / LF_TPB), LF_TPB>>>(
                    fa_split, (const F256Ext*)regions[cur_b], (F256Ext*)regions[oa],
                    (F256Ext*)regions[ob], half, r256);
                n256 = half;
            } else {
                long long half = n256 / 2;
                lf_fold_ext_pair<<<(unsigned)((half + LF_TPB - 1) / LF_TPB), LF_TPB>>>(
                    (const F256Ext*)regions[cur_f], (const F256Ext*)regions[cur_b],
                    (F256Ext*)regions[oa], (F256Ext*)regions[ob], half, r256);
                n256 = half;
            }
            LFCK(cudaGetLastError());
            cur_f = oa; cur_b = ob;
            LigMsg256 msg;
            if (j + 1 == k && i + 1 != r) {
                fa_split = (const F128*)regions[cur_f];
                split_words = 2 * n256;
                int sa, sb;
                two_free(sa, sb);
                (void)sb;
                lf_split_basis<<<(unsigned)((n256 + LF_TPB - 1) / LF_TPB), LF_TPB>>>(
                    (const F256Ext*)regions[cur_b], (F256Ext*)regions[sa], n256);
                LFCK(cudaGetLastError());
                cur_b = sa;
                msg = msg_fbase(fa_split, (const F256Ext*)regions[cur_b], n256);
            } else {
                msg = msg256((const F256Ext*)regions[cur_f], (const F256Ext*)regions[cur_b], n256);
            }
            lf_observe_msg(ch, out.transcript, msg);
        }
        int extension_dim = current_split_dim - k;
        int level = i + 1;

        if (i + 1 == r) {
            // yr in the clear (split coordinates of the final residual).
            out.yr.resize(2 * n256);
            LFCK(cudaMemcpy(out.yr.data(), regions[cur_f], out.yr.size() * sizeof(F128),
                            cudaMemcpyDeviceToHost));
            for (const F128& v : out.yr) ch.observe_f128(lf_toch(v));
            std::vector<F128> alpha;
            std::vector<size_t> queries;
            int rc = query_phase(level, out.final_open, alpha, queries);
            if (rc) return rc;
            // The trailing claim-batch grind (its β is unused — Rust discards it).
            ChF128 beta_c;
            out.claim_batch_nonces.push_back(ch.grind_pow_and_sample_f128(
                (uint32_t)C.claim_batch_grinding_bits[level], &beta_c));
            retire_prev();
            break;
        }

        current_split_dim = extension_dim + 1;
        int next_level = i + 2;
        F128* d_cwn;
        uint8_t* d_treen;
        long long bln;
        int lanesn;
        int rc = commit_level(next_level, d_cwn, d_treen, bln, lanesn);
        if (rc) return rc;
        rc = level_oods(next_level);
        if (rc) return rc;
        std::vector<F128> alpha;
        std::vector<size_t> queries;
        out.recursive_opens.emplace_back();
        rc = query_phase(level, out.recursive_opens.back(), alpha, queries);
        if (rc) return rc;
        rc = induce_introduce_glue(extension_dim, next_level, queries, alpha);
        if (rc) return rc;
        retire_prev();
        d_prev_cw = d_cwn;
        d_prev_tree = d_treen;
        prev_bl = bln;
        prev_lanes = lanesn;
        prev_owned = true;
        d_prev_cw_owned = d_cwn;
        d_prev_tree_owned = d_treen;
    }

    LFCK(A.release(d_eq2));
    LFCK(A.release(d_ind_basis));
    LFCK(A.release(d_ind_alpha));
    LFCK(A.release(d_ind_q));
    LFCK(A.release(regions[2]));
    LFCK(A.release(regions[3]));
    LFCK(A.release(d_p256_0));
    LFCK(A.release(d_p256_2));
    LFCK(A.release(d_out256));
    LFCK(A.release(d_p0));
    LFCK(A.release(d_p2));
    LFCK(A.release(d_podd));
    LFCK(A.release(d_u0));
    LFCK(A.release(d_u2));
    LFCK(A.release(d_hnew));
    return 0;
}
