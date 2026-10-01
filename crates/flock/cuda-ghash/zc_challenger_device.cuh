// On-device Fiat-Shamir challenger for the resident zerocheck tail. Bit-identical
// device port of challenger.hpp's Sha256 + FsChallenger observe/sample, so the tail's
// 23 rounds can run as a kernel sequence on one stream with NO host round-trips: each
// round a single-thread kernel observes the message and samples rho entirely on device.
// Only the challenger state is shipped H2D once before the loop and D2H once after.
#pragma once
#include "f128.cuh"
#include "sha256.cuh"     // sha256_compress (bit-identical to the host process)

// Device SHA-256 incremental state (mirrors challenger.hpp::Sha256).
struct ZcSha {
    uint32_t h[8];
    unsigned long long total_len;
    uint8_t buf[64];
    unsigned buf_len;
};
__device__ __forceinline__ void zcsha_reset(ZcSha& s) {
    s.h[0]=0x6a09e667u; s.h[1]=0xbb67ae85u; s.h[2]=0x3c6ef372u; s.h[3]=0xa54ff53au;
    s.h[4]=0x510e527fu; s.h[5]=0x9b05688cu; s.h[6]=0x1f83d9abu; s.h[7]=0x5be0cd19u;
    s.total_len = 0; s.buf_len = 0;
}
__device__ __forceinline__ void zcsha_update(ZcSha& s, const uint8_t* data, unsigned len) {
    s.total_len += len;
    while (len > 0) {
        unsigned take = 64 - s.buf_len; if (take > len) take = len;
        for (unsigned i = 0; i < take; i++) s.buf[s.buf_len + i] = data[i];
        s.buf_len += take; data += take; len -= take;
        if (s.buf_len == 64) { sha256_compress(s.h, s.buf); s.buf_len = 0; }
    }
}
// Finalize MUTATES (call on a copy to keep absorbing). Writes 32-byte big-endian digest.
__device__ __forceinline__ void zcsha_finalize(ZcSha& s, uint8_t out[32]) {
    unsigned long long bitlen = s.total_len * 8ull;
    s.buf[s.buf_len++] = 0x80;
    if (s.buf_len > 56) { while (s.buf_len < 64) s.buf[s.buf_len++] = 0; sha256_compress(s.h, s.buf); s.buf_len = 0; }
    while (s.buf_len < 56) s.buf[s.buf_len++] = 0;
    for (int i = 0; i < 8; i++) s.buf[56 + i] = (uint8_t)(bitlen >> (56 - 8 * i));
    sha256_compress(s.h, s.buf);
    for (int i = 0; i < 8; i++) {
        out[4*i]   = (uint8_t)(s.h[i] >> 24); out[4*i+1] = (uint8_t)(s.h[i] >> 16);
        out[4*i+2] = (uint8_t)(s.h[i] >> 8);  out[4*i+3] = (uint8_t)(s.h[i]);
    }
}
// FsChallenger op/kind tags (must match challenger.hpp).
#define ZC_OP_OBSERVE 0x03
#define ZC_OP_SQUEEZE 0x04
#define ZC_KIND_SCALAR 0x01
// One op's 16-byte header [op][kind][0;6][len u64 LE] — transcript-v2's
// word-aligned framing (mirrors challenger.hpp::absorb_header).
__device__ __forceinline__ void zc_absorb_header(ZcSha& s, uint8_t op, uint8_t kind,
                                                 unsigned long long len);
__device__ __forceinline__ void zc_le64(uint8_t* b, unsigned long long v) {
    for (int i = 0; i < 8; i++) b[i] = (uint8_t)(v >> (8 * i));
}
__device__ __forceinline__ unsigned long long zc_rd_le64(const uint8_t* b) {
    unsigned long long v = 0; for (int i = 0; i < 8; i++) v |= (unsigned long long)b[i] << (8 * i); return v;
}
__device__ __forceinline__ void zc_absorb_header(ZcSha& s, uint8_t op, uint8_t kind,
                                                 unsigned long long len) {
    uint8_t h[16];
    for (int i = 0; i < 16; i++) h[i] = 0;
    h[0] = op; h[1] = kind;
    zc_le64(h + 8, len);
    zcsha_update(s, h, 16);
}
__device__ __forceinline__ void zc_observe_f128(ZcSha& s, F128 v) {
    zc_absorb_header(s, ZC_OP_OBSERVE, ZC_KIND_SCALAR, 1ull);
    uint8_t b[16]; zc_le64(b, v.lo); zc_le64(b + 8, v.hi); zcsha_update(s, b, 16);
}
// sample_f128: absorb the OP_SQUEEZE header (which itself separates consecutive
// samples), then squeeze 16 bytes as SHA256(state || ctr=0) without mutating.
// The squeezed output is NOT re-absorbed (transcript-v2, matches the Rust).
__device__ __forceinline__ F128 zc_sample_f128(ZcSha& s) {
    zc_absorb_header(s, ZC_OP_SQUEEZE, ZC_KIND_SCALAR, 1ull);
    ZcSha h = s;                       // clone live state
    uint8_t cb[8]; zc_le64(cb, 0ull); zcsha_update(h, cb, 8);
    uint8_t block[32]; zcsha_finalize(h, block);
    uint8_t buf[16]; for (int i = 0; i < 16; i++) buf[i] = block[i];
    return F128{zc_rd_le64(buf), zc_rd_le64(buf + 8)};
}

// One tail round on device: observe (m1, mi), sample rho. Updates the persistent state
// in *st, writes rho to *rho_out (read by the next fold) and *rho_store (kept for host).
__global__ void advance_zerocheck_tail_challenger(ZcSha* st, const F128* m1, const F128* mi,
                              F128* rho_out, F128* rho_store, F128* m1log, F128* milog) {
    if (threadIdx.x || blockIdx.x) return;
    ZcSha s = *st;
    F128 a = *m1, b = *mi;
    zc_observe_f128(s, a);
    zc_observe_f128(s, b);
    F128 rho = zc_sample_f128(s);
    *st = s; *rho_out = rho; if (rho_store) *rho_store = rho;
    if (m1log) *m1log = a; if (milog) *milog = b;   // optional per-round log for validation
}

// ---- FUSED tail finisher ----
//
// One single-block launch that runs ALL remaining tail rounds (fold + split-eq
// message + on-device challenger) with __syncthreads() between rounds. The
// small rounds are pure overhead when host-driven: each pays ~27 us of kernel
// launches + two 16-byte D2H copies + host SHA for near-zero GPU work. The
// fully-resident per-round kernel sequence (advance_zerocheck_tail_challenger above) was ~0.1 ms
// slower than the host loop because single-thread GPU SHA also taxes the BIG
// rounds; the finisher is the hybrid — host challenger while rounds are
// bandwidth-bound, one fused kernel once op <= ZT_FINISH_OP.
//
// Round i (i = 0..rounds-1, continuing the host loop's numbering offset):
//   fold (cA,cB) len -> len/2 at rho, message over op = len/4 pairs with
//   eq = scales[i] * eqlo[(x<<(shift0+i)) & lomask] * eqhi[..>>lobits],
//   thread 0 observes (m1,minf) and samples the next rho (bit-identical
//   challenger). Logs m1/minf/rho per round; state written back at the end.
#include "zerocheck_tail.cuh"   // evaluate_zerocheck_split_equality (split-eq lookup)

#ifndef ZT_FINISH_OP
#define ZT_FINISH_OP (1LL << 10)   // hand off to the finisher once op <= this (swept: 2^9-2^10 optimal, TPB immaterial)
#endif
#ifndef ZT_FIN_TPB
#define ZT_FIN_TPB 256
#endif

__global__ void __launch_bounds__(ZT_FIN_TPB) finish_zerocheck_tail(F128* A, F128* B, F128* An, F128* Bn,
                                 const F128* __restrict__ eqlo, const F128* __restrict__ eqhi,
                                 int lobits, int shift0, const F128* __restrict__ scales,
                                 F128 rho0, int rounds, long long len0,
                                 ZcSha* state, F128* rhos_out, F128* m1_log, F128* minf_log) {
    __shared__ F128 s1[ZT_FIN_TPB];
    __shared__ F128 sinf[ZT_FIN_TPB];
    __shared__ F128 sh_rho;
    __shared__ ZcSha sh_st;
    int tid = threadIdx.x;
    if (tid == 0) sh_st = *state;
    F128 rho = rho0;
    long long len = len0;
    F128 *cA = A, *cB = B, *nA = An, *nB = Bn;
    __syncthreads();
    for (int i = 0; i < rounds; i++) {
        long long op = len / 4;
        int shift = shift0 + i;
        F256 g1a = {0, 0, 0, 0}, gia = {0, 0, 0, 0};
        for (long long x = tid; x < op; x += blockDim.x) {
            long long j = 4 * x;
            F128 a0 = cA[j], a1 = cA[j + 1], a2 = cA[j + 2], a3 = cA[j + 3];
            F128 b0 = cB[j], b1 = cB[j + 1], b2 = cB[j + 2], b3 = cB[j + 3];
            F128 af0 = f128_add(a0, ghash_mul_karatsuba(rho, f128_add(a0, a1)));
            F128 af1 = f128_add(a2, ghash_mul_karatsuba(rho, f128_add(a2, a3)));
            F128 bf0 = f128_add(b0, ghash_mul_karatsuba(rho, f128_add(b0, b1)));
            F128 bf1 = f128_add(b2, ghash_mul_karatsuba(rho, f128_add(b2, b3)));
            nA[2 * x] = af0; nA[2 * x + 1] = af1; nB[2 * x] = bf0; nB[2 * x + 1] = bf1;
            F128 e = evaluate_zerocheck_split_equality(eqlo, eqhi, x << shift, lobits);
            f256_xor(g1a, mul_unreduced_karatsuba(e, ghash_mul_karatsuba(af1, bf1)));
            f256_xor(gia, mul_unreduced_karatsuba(e, ghash_mul_karatsuba(
                              f128_add(af0, af1), f128_add(bf0, bf1))));
        }
        s1[tid] = f256_reduce(g1a); sinf[tid] = f256_reduce(gia);
        __syncthreads();
        for (int s = blockDim.x / 2; s > 0; s >>= 1) {
            if (tid < s) { s1[tid] = f128_add(s1[tid], s1[tid + s]); sinf[tid] = f128_add(sinf[tid], sinf[tid + s]); }
            __syncthreads();
        }
        if (tid == 0) {
            F128 m1 = ghash_mul_karatsuba(s1[0], scales[i]);
            F128 mi = ghash_mul_karatsuba(sinf[0], scales[i]);
            if (m1_log) m1_log[i] = m1;
            if (minf_log) minf_log[i] = mi;
            zc_observe_f128(sh_st, m1);
            zc_observe_f128(sh_st, mi);
            F128 r = zc_sample_f128(sh_st);
            rhos_out[i] = r; sh_rho = r;
        }
        __syncthreads();
        rho = sh_rho;
        { F128* t = cA; cA = nA; nA = t; t = cB; cB = nB; nB = t; }
        len /= 2;
    }
    if (tid == 0) *state = sh_st;
}
