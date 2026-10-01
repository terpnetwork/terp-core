// GF(2^256) as the quadratic extension of GHASH-basis GF(2^128) — port of
// crates/flock-core/src/field/gf2_256.rs for the F256 fold ladder
// (transcript "flock-ligerito-basis-f256-split-v0").
//
//   u^2 + u + x^-1 = 0    (x = the GHASH generator; Tr(x^-1) = 1)
//   element = c0 + c1·u   (two F128 limbs)
//
// The struct layout {c0, c1} matches the Rust #[repr(C)] F256, so an F256Ext
// array reinterprets in place as the Rust `split_coordinates` word list
// [c0_0, c1_0, c0_1, c1_1, ...] — the code switch is a pointer cast.
//
// Multiplication is Karatsuba (3 base products + a shift-and-fold for x^-1):
//   p0 = a0·b0, p1 = a1·b1, p2 = (a0+a1)·(b0+b1)
//   c0 = p0 + x^-1·p1
//   c1 = p2 + p0
// F256×F128 (base operand) is 2 products: (a0·b, a1·b).
//
// REQUIRES `F128` and `u64` to be defined by the includer (f128.cuh on the
// device side; a shim + ntt_host.hpp on a pure-host build). The `_hd` host
// functions additionally require ntt_host.hpp's `f128_mul_hd` to be declared
// first; the device functions require f128.cuh's `ghash_mul_karatsuba`.
//
// NOTE: f128.cuh separately defines a struct named `F256` — the 256-bit
// UNREDUCED clmul product. That type is unrelated; this one is `F256Ext`.
#pragma once

struct F256Ext {
    F128 c0, c1;
};

#ifdef __CUDACC__
#define F256X_FN __host__ __device__ __forceinline__
#else
#define F256X_FN inline
#endif

// x^-1 = x^127 + x^6 + x + 1 in the GHASH basis: one right shift, folding the
// dropped x^0 bit back as {0x43 low, top bit high} (gf2_256.rs::mul_by_x_inv).
F256X_FN F128 f128_mul_by_x_inv(F128 z) {
    u64 carry = z.lo & 1ull;
    u64 mask = (u64)0 - carry;
    F128 r;
    r.lo = ((z.lo >> 1) | (z.hi << 63)) ^ (0x43ull & mask);
    r.hi = (z.hi >> 1) ^ ((1ull << 63) & mask);
    return r;
}

F256X_FN F128 f256x_f128_xor(F128 a, F128 b) { return F128{a.lo ^ b.lo, a.hi ^ b.hi}; }

F256X_FN F256Ext f256x_zero() { return F256Ext{F128{0, 0}, F128{0, 0}}; }
F256X_FN F256Ext f256x_from_base(F128 v) { return F256Ext{v, F128{0, 0}}; }

F256X_FN F256Ext f256x_add(F256Ext a, F256Ext b) {
    return F256Ext{f256x_f128_xor(a.c0, b.c0), f256x_f128_xor(a.c1, b.c1)};
}

// u·B for B = b0 + b1·u:  u·(b0 + b1·u) = b1·(u + x^-1) + b0·u
//                        = x^-1·b1 + (b0 + b1)·u.   No base products needed.
F256X_FN F256Ext f256x_mul_by_u(F256Ext b) {
    return F256Ext{f128_mul_by_x_inv(b.c1), f256x_f128_xor(b.c0, b.c1)};
}

// The Karatsuba composition, shared verbatim between the device and host
// multiplies — only the base-field product primitive differs.
#define F256X_MUL_BODY(MUL)                                                    \
    F128 p0 = MUL(a.c0, b.c0);                                                 \
    F128 p1 = MUL(a.c1, b.c1);                                                 \
    F128 p2 = MUL(f256x_f128_xor(a.c0, a.c1), f256x_f128_xor(b.c0, b.c1));     \
    return F256Ext{f256x_f128_xor(p0, f128_mul_by_x_inv(p1)),                  \
                   f256x_f128_xor(p2, p0)};

#define F256X_MUL_BASE_BODY(MUL)                                               \
    return F256Ext{MUL(a.c0, b), MUL(a.c1, b)};

#ifdef __CUDACC__
// Device multiplies over the clmad kernel primitive (f128.cuh).
__device__ __forceinline__ F256Ext f256x_mul(F256Ext a, F256Ext b) {
    F256X_MUL_BODY(ghash_mul_karatsuba)
}
__device__ __forceinline__ F256Ext f256x_mul_base(F256Ext a, F128 b) {
    F256X_MUL_BASE_BODY(ghash_mul_karatsuba)
}
#endif

// Host multiplies over ntt_host.hpp's software clmul (declare it first).
inline F256Ext f256x_mul_hd(F256Ext a, F256Ext b) { F256X_MUL_BODY(f128_mul_hd) }
inline F256Ext f256x_mul_base_hd(F256Ext a, F128 b) { F256X_MUL_BASE_BODY(f128_mul_hd) }
