// Bit-for-bit validation of the GF(2^256) port (f256.cuh, host paths) against
// the real flock_core::field::F256, via the vectors dumped by
// src/bin/dump_f256_vectors.rs ("F256" format). Pure host C++ (no CUDA) — the
// device multiplies share the same Karatsuba composition (F256X_MUL_BODY) over
// the separately-validated clmad F128 multiply, so a pass here plus a green
// test_f128 pins both sides.
//
// Build:  make test_f256_host
// Run:    (repo root)  cargo run --release --bin dump_f256_vectors -- cuda-ghash/f256_vectors.bin
//         (cuda-ghash) ./test_f256_host f256_vectors.bin
#include <cstdio>
#include <cstdint>
#include <cstdlib>

typedef unsigned long long u64;
struct F128 { u64 lo, hi; };
#include "ntt_host.hpp"   // f128_mul_hd (software clmul, host)
#include "f256.cuh"

static u64 rd_u64(FILE* f) { u64 v; if (fread(&v, 8, 1, f) != 1) { printf("short read u64\n"); exit(1); } return v; }
static uint32_t rd_u32(FILE* f) { uint32_t v; if (fread(&v, 4, 1, f) != 1) { printf("short read u32\n"); exit(1); } return v; }
static F128 rd128(FILE* f) { F128 v; v.lo = rd_u64(f); v.hi = rd_u64(f); return v; }
static F256Ext rd256(FILE* f) { F256Ext v; v.c0 = rd128(f); v.c1 = rd128(f); return v; }
static bool eq128(F128 a, F128 b) { return a.lo == b.lo && a.hi == b.hi; }
static bool eq256(F256Ext a, F256Ext b) { return eq128(a.c0, b.c0) && eq128(a.c1, b.c1); }

int main(int argc, char** argv) {
    const char* path = argc > 1 ? argv[1] : "f256_vectors.bin";
    FILE* f = fopen(path, "rb");
    if (!f) { printf("cannot open %s (run dump_f256_vectors first)\n", path); return 1; }
    if (rd_u32(f) != 0x36353246u) { printf("bad file (want F256)\n"); return 1; }

    uint32_t n_mul = rd_u32(f);
    for (uint32_t i = 0; i < n_mul; i++) {
        F256Ext a = rd256(f), b = rd256(f), exp = rd256(f);
        F256Ext got = f256x_mul_hd(a, b);
        if (!eq256(got, exp)) { printf("MUL case %u FAIL\n", i); return 1; }
    }
    uint32_t n_base = rd_u32(f);
    for (uint32_t i = 0; i < n_base; i++) {
        F256Ext a = rd256(f); F128 b = rd128(f); F256Ext exp = rd256(f);
        F256Ext got = f256x_mul_base_hd(a, b);
        if (!eq256(got, exp)) { printf("MUL_BASE case %u FAIL\n", i); return 1; }
        // The base product must agree with the generic one on the lifted operand.
        if (!eq256(f256x_mul_hd(a, f256x_from_base(b)), exp)) { printf("MUL_BASE lift case %u FAIL\n", i); return 1; }
    }
    uint32_t n_xinv = rd_u32(f);
    for (uint32_t i = 0; i < n_xinv; i++) {
        F128 z = rd128(f), exp = rd128(f);
        F128 got = f128_mul_by_x_inv(z);
        if (!eq128(got, exp)) { printf("X_INV case %u FAIL\n", i); return 1; }
    }
    uint32_t n_ub = rd_u32(f);
    for (uint32_t i = 0; i < n_ub; i++) {
        F256Ext b = rd256(f), exp = rd256(f);
        F256Ext got = f256x_mul_by_u(b);
        if (!eq256(got, exp)) { printf("U_MUL case %u FAIL\n", i); return 1; }
    }
    fclose(f);
    printf("F256 OK: %u muls + %u base muls + %u x-inv + %u u·B match flock_core::field::F256 bit-for-bit\n",
           n_mul, n_base, n_xinv, n_ub);
    return 0;
}
