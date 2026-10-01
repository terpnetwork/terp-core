// CPU-structured (shift-reduce + convert-table) GPU port of zerocheck round-1.
// Validated end-to-end against the host reference. The point: do the
// outer F128 ghash only once per (outer-chunk, λ) instead of once per row — folding
// the 8 "small" dims in F8 (shift-then-reduce) and the 16 "medium" dims via a 64 KB
// convert table T[j][v]=γ^j·φ8(v). vs removed warp path's per-row eqB form this trades the 16
// eqB-shuffles/row for table lookups and cuts the ghash count ~8x.
//
// Layout: rows 2^(m-6) = 8 small(k) × 16 medium(j) × N_out(2^(m-13)). Column index
// col = o*128 + j*8 + k is contiguous, so one outer chunk = 128 contiguous columns.
// One WARP processes G outer chunks; lane owns output coords {lane, lane+32}.
// Accumulates raw = Σ_o eq_out[o]·chunk; the host/finalize scales by C_s·C_med.
#pragma once
#include "zerocheck_round1.cuh"

constexpr long long ZC_OUTER_CHUNKS_PER_WARP = 2;

// Discrete-log GF(2^8) tables: A·B = antilog[log[A]+log[B]] with a zero mask.
// 768 bytes total → live in shared (vs the 64 KB f8mul table in L2). Generator g=0x03;
// antilog sized 512 so log[A]+log[B] (≤508) needs no mod. Built on-device, once.
__device__ uint8_t d_zc_log[256];
__device__ uint8_t d_zc_antilog[512];
__global__ void build_zerocheck_logarithm_tables() {
    if (threadIdx.x || blockIdx.x) return;
    uint8_t a = 1;
    for (int i = 0; i < 255; i++) {
        d_zc_antilog[i] = a; d_zc_antilog[i + 255] = a; d_zc_log[a] = (uint8_t)i;
        a = (uint8_t)((a << 1) ^ ((a >> 7) * 0x1b)) ^ a;   // a *= 0x03
    }
    d_zc_antilog[510] = 1; d_zc_antilog[511] = d_zc_antilog[1];
    d_zc_log[0] = 0;       // sentinel; masked out when either operand is 0
}

// GF(2^8) reduce of a <=15-bit poly, AES poly x^8+x^4+x^3+x+1 (matches Rust gf8_reduce).
__device__ __forceinline__ uint8_t reduce_zerocheck_gf8_polynomial(uint16_t p) {
    uint16_t h = p >> 8;
    uint16_t t = (p & 0xff) ^ h ^ (uint16_t)(h << 1) ^ (uint16_t)(h << 3) ^ (uint16_t)(h << 4);
    uint16_t h2 = t >> 8;
    return (uint8_t)((t & 0xff) ^ h2 ^ (uint16_t)(h2 << 1) ^ (uint16_t)(h2 << 3) ^ (uint16_t)(h2 << 4));
}

// GHASH multiply-by-γ (γ=0x02): left shift by 1 bit, reduce by 0x87.
__device__ __forceinline__ F128 multiply_zerocheck_value_by_generator(F128 z) {
    u64 mask = (u64)0 - (z.hi >> 63);
    return F128{ (z.lo << 1) ^ (0x87 & mask), (z.hi << 1) | (z.lo >> 63) };
}

// Variant 3: drop the 64 KB convert table. chunk = Σ_j γ^j·φ8(sn_j) is a reverse
// Horner fold in γ (γ-multiply = multiply_zerocheck_value_by_generator, a shift — not a ghash), so we only need
// the 4 KB φ8 table in shared (keeps occupancy high). j-loop runs 15→0 so the fold
// fuses with no extra storage. All 32 lanes build the extended words.
template <int W>
__global__ void zerocheck_first_round_cpu_structured(const uint8_t* __restrict__ a_packed,
                                    const uint8_t* __restrict__ b_packed,
                                    const uint8_t* __restrict__ c_packed,
                                    const F128* __restrict__ eq_out,
                                    const u64* __restrict__ t0,
                                    const uint8_t* __restrict__ f8mul,
                                    const F128* __restrict__ phi,
                                    long long n_out, long long G,
                                    F128* __restrict__ raw_ab, F128* __restrict__ raw_c) {
    __shared__ u64 s_t0[256 * 8];                 // 16 KB
    __shared__ F128 s_phi[256];                   // 4 KB  (replaces the 64 KB convert table)
    __shared__ u64 s_scol[W * 24];
    __shared__ u64 s_wbuf[W * 192];
    __shared__ uint8_t s_log[256];
    __shared__ uint8_t s_antilog[512];
    for (int i = threadIdx.x; i < 256; i += blockDim.x) s_log[i] = d_zc_log[i];
    for (int i = threadIdx.x; i < 512; i += blockDim.x) s_antilog[i] = d_zc_antilog[i];
    for (int i = threadIdx.x; i < 256 * 8; i += blockDim.x) s_t0[i] = t0[i];
    for (int i = threadIdx.x; i < 256; i += blockDim.x) s_phi[i] = phi[i];
    __syncthreads();

    int wid = threadIdx.x >> 5, lane = threadIdx.x & 31;
    u64* scol = s_scol + wid * 24;
    u64* wbuf = s_wbuf + wid * 192;
    long long warp_id = (long long)blockIdx.x * W + wid;
    long long o0 = warp_id * G, o1 = o0 + G;
    if (o1 > n_out) o1 = n_out;
    if (o0 >= o1) return;

    int wlo = lane >> 3, whi = wlo + 4, sh = (lane & 7) * 8;
    F128 pab0{0, 0}, pab1{0, 0}, pc0{0, 0}, pc1{0, 0};

    for (long long o = o0; o < o1; o++) {
        F128 eq_o = eq_out[o];
        F128 chunk_ab0{0, 0}, chunk_ab1{0, 0}, chunk_c0{0, 0}, chunk_c1{0, 0};
        for (int j = 15; j >= 0; j--) {            // reverse for Horner
            long long col0 = o * 128 + j * 8;
            long long base = col0 * 8;
            if (lane < 24) {
                const uint8_t* Wt = (lane < 8) ? a_packed : (lane < 16) ? b_packed : c_packed;
                int cl = lane & 7;
                scol[lane] = *(const u64*)(Wt + base + cl * 8);
            }
            __syncwarp();
#pragma unroll
            for (int r = 0; r < 6; r++) {
                int bld = lane + 32 * r;
                int cl = bld / 24, win = bld - cl * 24, wt = win >> 3, wcol = win & 7;
                u64 src = scol[wt * 8 + cl];
                u64 word = 0;
#pragma unroll
                for (int b = 0; b < 8; b++)
                    word ^= s_t0[(int)((src >> (8 * b)) & 0xff) * 8 + (wcol ^ b)];
                wbuf[cl * 24 + win] = word;
            }
            __syncwarp();
            uint16_t aacc0 = 0, aacc1 = 0, cacc0 = 0, cacc1 = 0;
#pragma unroll
            for (int k = 0; k < 8; k++) {
                const u64* wc = wbuf + k * 24;
                uint8_t aL = (uint8_t)(wc[wlo]      >> sh), aH = (uint8_t)(wc[whi]      >> sh);
                uint8_t bL = (uint8_t)(wc[8 + wlo]  >> sh), bH = (uint8_t)(wc[8 + whi]  >> sh);
                uint8_t cL = (uint8_t)(wc[16 + wlo] >> sh), cH = (uint8_t)(wc[16 + whi] >> sh);
                // A·B = antilog[log A + log B], 0-masked; 768 B tables in shared.
                uint8_t p0 = s_antilog[(int)s_log[aL] + s_log[bL]] & (uint8_t)(-(int)(aL && bL));
                uint8_t p1 = s_antilog[(int)s_log[aH] + s_log[bH]] & (uint8_t)(-(int)(aH && bH));
                aacc0 ^= (uint16_t)p0 << k;
                aacc1 ^= (uint16_t)p1 << k;
                cacc0 ^= (uint16_t)cL << k;
                cacc1 ^= (uint16_t)cH << k;
            }
            chunk_ab0 = f128_add(multiply_zerocheck_value_by_generator(chunk_ab0), s_phi[reduce_zerocheck_gf8_polynomial(aacc0)]);
            chunk_ab1 = f128_add(multiply_zerocheck_value_by_generator(chunk_ab1), s_phi[reduce_zerocheck_gf8_polynomial(aacc1)]);
            chunk_c0  = f128_add(multiply_zerocheck_value_by_generator(chunk_c0),  s_phi[reduce_zerocheck_gf8_polynomial(cacc0)]);
            chunk_c1  = f128_add(multiply_zerocheck_value_by_generator(chunk_c1),  s_phi[reduce_zerocheck_gf8_polynomial(cacc1)]);
            __syncwarp();
        }
        pab0 = f128_add(pab0, ghash_mul_karatsuba(eq_o, chunk_ab0));
        pab1 = f128_add(pab1, ghash_mul_karatsuba(eq_o, chunk_ab1));
        pc0  = f128_add(pc0,  ghash_mul_karatsuba(eq_o, chunk_c0));
        pc1  = f128_add(pc1,  ghash_mul_karatsuba(eq_o, chunk_c1));
    }
    atomicXor((unsigned long long*)&raw_ab[lane].lo, pab0.lo);
    atomicXor((unsigned long long*)&raw_ab[lane].hi, pab0.hi);
    atomicXor((unsigned long long*)&raw_ab[lane + 32].lo, pab1.lo);
    atomicXor((unsigned long long*)&raw_ab[lane + 32].hi, pab1.hi);
    atomicXor((unsigned long long*)&raw_c[lane].lo, pc0.lo);
    atomicXor((unsigned long long*)&raw_c[lane].hi, pc0.hi);
    atomicXor((unsigned long long*)&raw_c[lane + 32].lo, pc1.lo);
    atomicXor((unsigned long long*)&raw_c[lane + 32].hi, pc1.hi);
}

// Multiply all 64 outputs by the global scale C_s·C_med (= eq_small[0]·eq_med[0]).
__global__ void scale_zerocheck_first_round(F128* ab, F128* c, F128 scale) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < 64) { ab[i] = ghash_mul_karatsuba(ab[i], scale); c[i] = ghash_mul_karatsuba(c[i], scale); }
}

// Launch the canonical CPU-structured round-1 kernel.
inline void launch_zerocheck_first_round_cpu_structured(const uint8_t* d_a, const uint8_t* d_b, const uint8_t* d_c,
                                       const F128* d_eq_out, long long n_out, F128 scale,
                                       F128* d_round1_ab, F128* d_round1_c) {
// Warps per block. 14, not the 16 that fits the 48 KB static-shared ceiling: at 72
// registers/thread a second block per SM needs 2·W·32·72 <= 65536, i.e. W <= 14.22.
// W=16 clears the shared limit but misses the register file, so it runs ONE block
// per SM (16 warps) where W=14 runs two (28 warps) — measured -8% round-1 at m=29,
// 32 and 33 alike, and W=15 falls straight back to W=16's time. Re-derive this if
// the kernel's register count moves; the cliff is sharp on both sides.
    constexpr int W = 14;
    static bool s_log_up = false;
    if (!s_log_up) { build_zerocheck_logarithm_tables<<<1, 1>>>(); s_log_up = true; }
    constexpr long long G = ZC_OUTER_CHUNKS_PER_WARP;
    long long warps = (n_out + G - 1) / G;
    int blocks = (int)((warps + W - 1) / W);
    cudaMemset(d_round1_ab, 0, 64 * sizeof(F128));
    cudaMemset(d_round1_c, 0, 64 * sizeof(F128));
    zerocheck_first_round_cpu_structured<W><<<blocks, W * 32>>>(d_a, d_b, d_c, d_eq_out, g_zc_t0, g_zc_f8mul,
                                               g_zc_phi, n_out, G, d_round1_ab, d_round1_c);
    scale_zerocheck_first_round<<<1, 64>>>(d_round1_ab, d_round1_c, scale);
}
