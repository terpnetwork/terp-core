// Host-portable (pure C++, no CUDA) GF(2^128) field math + LCH-NTT twiddle
// table. Shared by the CUDA kernel header (ntt_f128.cuh) and the CPU oracle
// checker (host_check_ntt.cpp), so the twiddle schedule — the one correctness
// risk in the GPU port — is validated bit-for-bit on the host before it ever
// runs on the GPU.
//
// REQUIRES `F128` (two u64 fields `lo`,`hi`) and `u64` to already be defined by
// the includer (f128.cuh on the device side; a tiny shim on the host side).
//
// Field semantics mirror flare's src/field/gf2_128.rs and the twiddle schedule
// mirrors src/ntt/additive_ntt_f128.rs (generate_evals_from_subspace + twiddle
// + span_get). Any correct GF(2^128) multiply yields the same element, so this
// software multiply matches flare's clmul-based one bit-for-bit.
#pragma once
#include <vector>

inline void clmul64_hd(u64 a, u64 b, u64 &lo, u64 &hi) {
    lo = 0; hi = 0;
    for (int i = 0; i < 64; i++) {
        u64 m = (u64)0 - ((a >> i) & 1ull);          // 0 or all-ones
        lo ^= (b << i) & m;
        hi ^= (i ? (b >> (64 - i)) : 0ull) & m;
    }
}

// Verbatim port of f128.cuh's ghash_reduce. x^128 = x^7 + x^2 + x + 1.
inline F128 ghash_reduce_hd(u64 r0, u64 r1, u64 r2, u64 r3) {
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

inline F128 f128_add_hd(F128 a, F128 b) { return F128{a.lo ^ b.lo, a.hi ^ b.hi}; }

inline F128 f128_mul_hd(F128 a, F128 b) {
    u64 ll_lo, ll_hi, lh_lo, lh_hi, hl_lo, hl_hi, hh_lo, hh_hi;
    clmul64_hd(a.lo, b.lo, ll_lo, ll_hi);
    clmul64_hd(a.lo, b.hi, lh_lo, lh_hi);
    clmul64_hd(a.hi, b.lo, hl_lo, hl_hi);
    clmul64_hd(a.hi, b.hi, hh_lo, hh_hi);
    return ghash_reduce_hd(ll_lo, ll_hi ^ lh_lo ^ hl_lo, hh_lo ^ lh_hi ^ hl_hi, hh_hi);
}

// Multiplicative inverse via Fermat: a^(2^128 - 2). The exponent has bits 1..127
// set (bit 0 clear), so LSB-first square-and-multiply multiplies in `base` on
// every step except the first. Used only for the ~L row normalizations.
inline F128 f128_inv_host(F128 a) {
    F128 result{1ull, 0ull};                          // multiplicative identity = x^0
    F128 base = a;
    for (int i = 0; i < 128; i++) {
        if (i >= 1) result = f128_mul_hd(result, base);
        base = f128_mul_hd(base, base);
    }
    return result;
}

// ---------------------------------------------------------------------------
// Twiddle table. Port of generate_evals_from_subspace for the *standard* basis
// {1, x, x^2, ..., x^(L-1)} = F128{1<<i, 0}. Per forward layer `l` we need the
// span basis evals[L - l - 1][1..] (length l). `data[off[l] + j]` is its j-th
// element; twiddle(l, block) = XOR of data[off[l]+j] over set bits j of block.
// ---------------------------------------------------------------------------
struct TwiddleTable {
    std::vector<F128> data;   // flattened per-layer span bases, total L*(L-1)/2
    std::vector<int>  off;    // off[l] = start of layer l's basis (length l)
    int L = 0;
};

inline TwiddleTable build_twiddle_table(int L) {
    std::vector<std::vector<F128>> evals;              // evals[i] has length L - i
    evals.reserve(L);
    {
        std::vector<F128> basis(L);
        for (int i = 0; i < L; i++) basis[i] = F128{1ull << i, 0ull};
        evals.push_back(std::move(basis));
    }
    for (int i = 1; i < L; i++) {
        const std::vector<F128>& prev = evals[i - 1];
        std::vector<F128> row;
        row.reserve(prev.size() - 1);
        for (size_t k = 1; k < prev.size(); k++) {
            // W_i(b_{i+k}) = prev[k] * (prev[k] + prev[0])
            row.push_back(f128_mul_hd(prev[k], f128_add_hd(prev[k], prev[0])));
        }
        evals.push_back(std::move(row));
    }
    // Normalize each row by its 0-th element (= W_i(b_i)).
    for (auto& row : evals) {
        F128 inv = f128_inv_host(row[0]);
        for (auto& v : row) v = f128_mul_hd(v, inv);
    }

    // Flatten: layer l (0..L-1) uses evals[L - l - 1][1..], length l.
    TwiddleTable tt;
    tt.L = L;
    tt.off.resize(L);
    int total = 0;
    for (int l = 0; l < L; l++) { tt.off[l] = total; total += l; }
    tt.data.resize(total);
    for (int l = 0; l < L; l++) {
        const std::vector<F128>& row = evals[L - l - 1];   // length l+1
        for (int j = 0; j < l; j++) tt.data[tt.off[l] + j] = row[1 + j];
    }
    return tt;
}

// twiddle(layer, block) from a flattened table: XOR of the layer's span basis
// at the set bits of `block`. (Mirrors the device inline in ntt_f128.cuh.)
inline F128 twiddle_from_table(const TwiddleTable& tt, int layer, long long block) {
    F128 tw{0ull, 0ull};
    const F128* basis = tt.data.data() + tt.off[layer];
    for (int j = 0; j < layer; j++)
        if ((block >> j) & 1ull) tw = f128_add_hd(tw, basis[j]);
    return tw;
}
