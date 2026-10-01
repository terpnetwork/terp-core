// GF(2^128) in GHASH form on CUDA, using the native `clmad` instruction
// (PTX ISA 9.3, SASS CLMAD.LO/.HI on sm_120 Blackwell).
//
// Direct port of flare-avx `src/field/gf2_128.rs`:
//   irreducible poly  p = x^128 + x^7 + x^2 + x + 1
//   layout            lo = coeffs x^0..x^63,  hi = coeffs x^64..x^127
//
// The CPU code uses 64x64->128 carryless products (ARM PMULL / x86 PCLMULQDQ).
// `clmad` gives the *halves* of that product separately, plus a fused XOR:
//   clmad.lo.u64 d,a,b,c :  d = lo64(clmul(a,b)) ^ c
//   clmad.hi.u64 d,a,b,c :  d = hi64(clmul(a,b)) ^ c
// so one PMULL == one clmad.lo + one clmad.hi, and the GHASH cross-term /
// reduction XORs fold into the free `^ c` operand.
#pragma once
#include <cstdint>

typedef unsigned long long u64;

struct __align__(16) F128 {
    u64 lo;
    u64 hi;
};

struct F256 {            // 256-bit unreduced product (r0=lowest .. r3=highest)
    u64 r0, r1, r2, r3;
};

// ---------------------------------------------------------------------------
// clmad primitives — the new hardware instruction.
// Non-volatile asm: lets the scheduler overlap independent clmads (honest
// throughput). Each call's mnemonic differs (.lo vs .hi) so no bad CSE.
// ---------------------------------------------------------------------------
__device__ __forceinline__ u64 clmad_lo(u64 a, u64 b, u64 c) {
    u64 d;
    asm("clmad.lo.u64 %0, %1, %2, %3;" : "=l"(d) : "l"(a), "l"(b), "l"(c));
    return d;
}
__device__ __forceinline__ u64 clmad_hi(u64 a, u64 b, u64 c) {
    u64 d;
    asm("clmad.hi.u64 %0, %1, %2, %3;" : "=l"(d) : "l"(a), "l"(b), "l"(c));
    return d;
}
__device__ __forceinline__ u64 clmul_lo(u64 a, u64 b) { return clmad_lo(a, b, 0); }
__device__ __forceinline__ u64 clmul_hi(u64 a, u64 b) { return clmad_hi(a, b, 0); }

// ---------------------------------------------------------------------------
// Software shift-XOR 64x64 carryless product — the "what clmad replaces"
// baseline. Verbatim logic of `software::clmul64`, branch made branchless.
// ---------------------------------------------------------------------------
__device__ __forceinline__ void clmul64_sw(u64 a, u64 b, u64 &lo, u64 &hi) {
    lo = 0; hi = 0;
#pragma unroll
    for (int i = 0; i < 64; i++) {
        u64 m = (u64)0 - ((a >> i) & 1ull);   // 0 or all-ones
        lo ^= (b << i) & m;
        hi ^= (i ? (b >> (64 - i)) : 0ull) & m;
    }
}

// ---------------------------------------------------------------------------
// Reduction mod p. Verbatim port of `ghash_reduce` (works regardless of how
// the 256-bit product was formed). x^128 = x^7 + x^2 + x + 1.
// ---------------------------------------------------------------------------
__device__ __forceinline__ F128 ghash_reduce(u64 r0, u64 r1, u64 r2, u64 r3) {
    u64 s1_lo = r2 << 1;
    u64 s1_hi = (r3 << 1) | (r2 >> 63);
    u64 s2_lo = r2 << 2;
    u64 s2_hi = (r3 << 2) | (r2 >> 62);
    u64 s7_lo = r2 << 7;
    u64 s7_hi = (r3 << 7) | (r2 >> 57);

    u64 t_lo = r2 ^ s1_lo ^ s2_lo ^ s7_lo;
    u64 t_hi = r3 ^ s1_hi ^ s2_hi ^ s7_hi;

    u64 ov   = (r3 >> 63) ^ (r3 >> 62) ^ (r3 >> 57);
    u64 corr = ov ^ (ov << 1) ^ (ov << 2) ^ (ov << 7);

    F128 out;
    out.lo = r0 ^ t_lo ^ corr;
    out.hi = r1 ^ t_hi;
    return out;
}

// ---------------------------------------------------------------------------
// 256-bit unreduced schoolbook product (clmad-fused). Port of
// `software::ghash_mul_unreduced`: the lh+hl cross fold rides clmad's `^ c`.
// ---------------------------------------------------------------------------
__device__ __forceinline__ F256 mul_unreduced_clmad(F128 a, F128 b) {
    u64 r0    = clmul_lo(a.lo, b.lo);                 // ll_lo
    u64 ll_hi = clmul_hi(a.lo, b.lo);
    u64 lh_lo = clmul_lo(a.lo, b.hi);
    u64 r1    = clmad_lo(a.hi, b.lo, ll_hi ^ lh_lo);  // hl_lo ^ ll_hi ^ lh_lo
    u64 lh_hi = clmul_hi(a.lo, b.hi);
    u64 hl_hi = clmul_hi(a.hi, b.lo);
    u64 r2    = clmad_lo(a.hi, b.hi, lh_hi ^ hl_hi);  // hh_lo ^ lh_hi ^ hl_hi
    u64 r3    = clmul_hi(a.hi, b.hi);                 // hh_hi
    return F256{r0, r1, r2, r3};
}

// 256-bit unreduced product via Karatsuba (6 CLMAD). For deferred-reduction
// dot products: XOR-accumulate these, reduce once (reduction commutes w/ XOR).
__device__ __forceinline__ F256 mul_unreduced_karatsuba(F128 a, F128 b) {
    u64 p0_lo = clmul_lo(a.lo, b.lo);
    u64 p0_hi = clmul_hi(a.lo, b.lo);
    u64 p1_lo = clmul_lo(a.hi, b.hi);
    u64 p1_hi = clmul_hi(a.hi, b.hi);
    u64 am = a.lo ^ a.hi, bm = b.lo ^ b.hi;
    u64 cross_lo = clmad_lo(am, bm, p0_lo ^ p1_lo);
    u64 cross_hi = clmad_hi(am, bm, p0_hi ^ p1_hi);
    return F256{p0_lo, p0_hi ^ cross_lo, p1_lo ^ cross_hi, p1_hi};
}

// Same, using only the software shift-XOR clmul (no clmad) — baseline.
__device__ __forceinline__ F256 mul_unreduced_sw(F128 a, F128 b) {
    u64 ll_lo, ll_hi, lh_lo, lh_hi, hl_lo, hl_hi, hh_lo, hh_hi;
    clmul64_sw(a.lo, b.lo, ll_lo, ll_hi);
    clmul64_sw(a.lo, b.hi, lh_lo, lh_hi);
    clmul64_sw(a.hi, b.lo, hl_lo, hl_hi);
    clmul64_sw(a.hi, b.hi, hh_lo, hh_hi);
    return F256{ll_lo, ll_hi ^ lh_lo ^ hl_lo, hh_lo ^ lh_hi ^ hl_hi, hh_hi};
}

// ---------------------------------------------------------------------------
// Full field multiply variants.
// ---------------------------------------------------------------------------

// Schoolbook 8-clmad + scalar reduction. Port of `ghash_mul_schoolbook`.
__device__ __forceinline__ F128 ghash_mul_schoolbook(F128 a, F128 b) {
    F256 u = mul_unreduced_clmad(a, b);
    return ghash_reduce(u.r0, u.r1, u.r2, u.r3);
}

// Binius: schoolbook + 2-stage recursive reduction, all reduction XORs fused
// into clmad. Port of `x86_64::ghash_mul_binius` — the default CPU `Mul`.
__device__ __forceinline__ F128 ghash_mul_binius(F128 a, F128 b) {
    u64 t0_lo = clmul_lo(a.lo, b.lo);
    u64 t0_hi = clmul_hi(a.lo, b.lo);
    u64 t1_lo = clmad_lo(a.lo, b.hi, clmul_lo(a.hi, b.lo)); // t1a_lo ^ t1b_lo
    u64 t1_hi = clmad_hi(a.lo, b.hi, clmul_hi(a.hi, b.lo)); // t1a_hi ^ t1b_hi
    u64 t2_lo = clmul_lo(a.hi, b.hi);
    u64 t2_hi = clmul_hi(a.hi, b.hi);

    // First reduce: t1 += x^64 * t2  (mod p)
    t1_hi ^= t2_lo;                       // {0, t2.lo} folded into t1.hi
    t1_lo  = clmad_lo(t2_hi, 0x87, t1_lo);
    t1_hi  = clmad_hi(t2_hi, 0x87, t1_hi);

    // Second reduce: t0 += x^64 * t1  (mod p)
    t0_hi ^= t1_lo;
    t0_lo  = clmad_lo(t1_hi, 0x87, t0_lo);
    t0_hi  = clmad_hi(t1_hi, 0x87, t0_hi);

    return F128{t0_lo, t0_hi};
}

// Karatsuba: 3 carryless products (6 CLMAD) + scalar reduction. Port of
// `ghash_mul_karatsuba`. The middle term's cross XORs fold into clmad's `^ c`:
//   cross = pm ^ p0 ^ p1  ==  clmad(am, bm, p0 ^ p1).
__device__ __forceinline__ F128 ghash_mul_karatsuba(F128 a, F128 b) {
    u64 p0_lo = clmul_lo(a.lo, b.lo);
    u64 p0_hi = clmul_hi(a.lo, b.lo);
    u64 p1_lo = clmul_lo(a.hi, b.hi);
    u64 p1_hi = clmul_hi(a.hi, b.hi);
    u64 am = a.lo ^ a.hi, bm = b.lo ^ b.hi;
    u64 cross_lo = clmad_lo(am, bm, p0_lo ^ p1_lo);   // pm_lo ^ p0_lo ^ p1_lo
    u64 cross_hi = clmad_hi(am, bm, p0_hi ^ p1_hi);   // pm_hi ^ p0_hi ^ p1_hi
    return ghash_reduce(p0_lo, p0_hi ^ cross_lo, p1_lo ^ cross_hi, p1_hi);
}

// Software baseline full multiply (shift-XOR clmul + reduction).
__device__ __forceinline__ F128 ghash_mul_sw(F128 a, F128 b) {
    F256 u = mul_unreduced_sw(a, b);
    return ghash_reduce(u.r0, u.r1, u.r2, u.r3);
}

// ---------------------------------------------------------------------------
// Helpers: XOR (field add), deferred-product XOR accumulate, reduce.
// ---------------------------------------------------------------------------
__device__ __forceinline__ F128 f128_add(F128 a, F128 b) {
    return F128{a.lo ^ b.lo, a.hi ^ b.hi};
}
__device__ __forceinline__ void f256_xor(F256 &acc, const F256 &p) {
    acc.r0 ^= p.r0; acc.r1 ^= p.r1; acc.r2 ^= p.r2; acc.r3 ^= p.r3;
}
__device__ __forceinline__ F128 f256_reduce(const F256 &u) {
    return ghash_reduce(u.r0, u.r1, u.r2, u.r3);
}
