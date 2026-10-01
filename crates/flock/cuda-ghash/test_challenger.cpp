// Byte-for-byte validation of the host FsChallenger port (challenger.hpp) against
// the real flock FsChallenger, via the script dumped by
// src/bin/dump_challenger_vectors.rs (CHLG format). Pure host C++ (no CUDA).
//
// Replays the op sequence; for every sample / sample_vec / grind op, asserts the
// host port reproduces the real challenger's output bit-for-bit. If any earlier
// observe diverged, the squeezed challenges downstream would mismatch — so a full
// pass means the whole transcript state stays in lockstep.
//
// Build:  make test_challenger
// Run:    (repo root)  cargo run --release --bin dump_challenger_vectors -- cuda-ghash/challenger_vectors.bin
//         (cuda-ghash) ./test_challenger challenger_vectors.bin
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include "challenger.hpp"

static uint8_t rd_u8(FILE* f) { uint8_t v; if (fread(&v, 1, 1, f) != 1) { printf("short read u8\n"); exit(1); } return v; }
static uint32_t rd_u32(FILE* f) { uint32_t v; if (fread(&v, 4, 1, f) != 1) { printf("short read u32\n"); exit(1); } return v; }
static uint64_t rd_u64(FILE* f) { uint64_t v; if (fread(&v, 8, 1, f) != 1) { printf("short read u64\n"); exit(1); } return v; }
static ChF128 rd_f128(FILE* f) { uint64_t v[2]; if (fread(v, 8, 2, f) != 2) { printf("short read f128\n"); exit(1); } return ChF128{v[0], v[1]}; }
static bool eq(ChF128 a, ChF128 b) { return a.lo == b.lo && a.hi == b.hi; }

int main(int argc, char** argv) {
    const char* path = argc > 1 ? argv[1] : "challenger_vectors.bin";
    FILE* f = fopen(path, "rb");
    if (!f) { printf("cannot open %s (run dump_challenger_vectors first)\n", path); return 1; }

    if (rd_u32(f) != 0x43484C47u) { printf("bad file (want CHLG)\n"); return 1; }
    uint32_t dlen = rd_u32(f);
    std::vector<uint8_t> domain(dlen);
    if (dlen && fread(domain.data(), 1, dlen, f) != dlen) { printf("short read domain\n"); return 1; }
    uint32_t n_ops = rd_u32(f);

    FsChallenger ch(domain.data(), dlen);
    printf("CHLG: domain='%.*s' n_ops=%u\n", (int)dlen, (const char*)domain.data(), n_ops);

    int samples = 0, grinds = 0;
    for (uint32_t op = 0; op < n_ops; op++) {
        uint8_t t = rd_u8(f);
        switch (t) {
            case 1: { // observe_f128
                ChF128 v = rd_f128(f); ch.observe_f128(v); break;
            }
            case 2: { // observe_bytes
                uint32_t n = rd_u32(f); std::vector<uint8_t> b(n);
                if (n && fread(b.data(), 1, n, f) != n) { printf("short read bytes\n"); return 1; }
                ch.observe_bytes(b.data(), n); break;
            }
            case 3: { // sample_f128 + expected
                ChF128 exp = rd_f128(f); ChF128 got = ch.sample_f128();
                if (!eq(got, exp)) {
                    printf("SAMPLE op %u FAIL: got %016llx:%016llx exp %016llx:%016llx\n", op,
                           (unsigned long long)got.hi, (unsigned long long)got.lo,
                           (unsigned long long)exp.hi, (unsigned long long)exp.lo);
                    return 1;
                }
                samples++; break;
            }
            case 4: { // observe_label
                uint32_t n = rd_u32(f); std::vector<uint8_t> b(n);
                if (n && fread(b.data(), 1, n, f) != n) { printf("short read label\n"); return 1; }
                ch.observe_label(b.data(), n); break;
            }
            case 5: { // grind + expected nonce
                uint32_t bits = rd_u32(f); uint64_t exp = rd_u64(f);
                uint64_t got = ch.grind_pow(bits);
                if (got != exp) { printf("GRIND op %u (bits=%u) FAIL: got %llu exp %llu\n",
                                         op, bits, (unsigned long long)got, (unsigned long long)exp); return 1; }
                grinds++; break;
            }
            case 6: { // observe_f128_slice
                uint32_t n = rd_u32(f); std::vector<ChF128> v(n);
                for (uint32_t i = 0; i < n; i++) v[i] = rd_f128(f);
                ch.observe_f128_slice(v.data(), n); break;
            }
            case 7: { // sample_f128_vec + expected
                uint32_t n = rd_u32(f); std::vector<ChF128> exp(n);
                for (uint32_t i = 0; i < n; i++) exp[i] = rd_f128(f);
                std::vector<ChF128> got(n); ch.sample_f128_vec(got.data(), n);
                for (uint32_t i = 0; i < n; i++) if (!eq(got[i], exp[i])) {
                    printf("SAMPLE_VEC op %u idx %u FAIL\n", op, i); return 1;
                }
                samples++; break;
            }
            case 8: { // sample_distinct_queries + expected positions
                uint64_t block_len = rd_u64(f); uint32_t count = rd_u32(f);
                std::vector<size_t> exp(count);
                for (uint32_t i = 0; i < count; i++) exp[i] = (size_t)rd_u64(f);
                std::vector<size_t> got = ch.sample_distinct_queries((size_t)block_len, count);
                if (got.size() != count) { printf("QUERIES op %u FAIL: size %zu != %u\n", op, got.size(), count); return 1; }
                for (uint32_t i = 0; i < count; i++) if (got[i] != exp[i]) {
                    printf("QUERIES op %u idx %u FAIL: got %zu exp %zu\n", op, i, got[i], exp[i]); return 1;
                }
                samples++; break;
            }
            case 9: { // sample_f256 + expected (c0, c1)
                ChF128 e0 = rd_f128(f), e1 = rd_f128(f);
                ChF256 got = ch.sample_f256();
                if (!eq(got.c0, e0) || !eq(got.c1, e1)) { printf("SAMPLE_F256 op %u FAIL\n", op); return 1; }
                samples++; break;
            }
            case 10: { // observe_f256
                ChF128 c0 = rd_f128(f), c1 = rd_f128(f);
                ch.observe_f256(ChF256{c0, c1}); break;
            }
            case 11: { // fused grind + scalar squeeze
                uint32_t bits = rd_u32(f); uint64_t en = rd_u64(f); ChF128 er = rd_f128(f);
                ChF128 got; uint64_t gn = ch.grind_pow_and_sample_f128(bits, &got);
                if (gn != en || !eq(got, er)) { printf("GRIND_SAMPLE op %u (bits=%u) FAIL\n", op, bits); return 1; }
                samples++; grinds++; break;
            }
            case 12: { // fused grind + vector squeeze
                uint32_t bits = rd_u32(f), n = rd_u32(f); uint64_t en = rd_u64(f);
                std::vector<ChF128> exp(n);
                for (uint32_t i = 0; i < n; i++) exp[i] = rd_f128(f);
                std::vector<ChF128> got(n);
                uint64_t gn = ch.grind_pow_and_sample_f128_vec(bits, got.data(), n);
                if (gn != en) { printf("GRIND_SAMPLE_VEC op %u nonce FAIL\n", op); return 1; }
                for (uint32_t i = 0; i < n; i++) if (!eq(got[i], exp[i])) {
                    printf("GRIND_SAMPLE_VEC op %u idx %u FAIL\n", op, i); return 1;
                }
                samples++; grinds++; break;
            }
            case 13: { // stratified query phase: grind + one vec squeeze + mapping
                uint32_t bits = rd_u32(f), lbl = rd_u32(f), count = rd_u32(f);
                uint64_t en = rd_u64(f);
                std::vector<size_t> exp(count);
                for (uint32_t i = 0; i < count; i++) exp[i] = (size_t)rd_u64(f);
                std::vector<uint32_t> depths = stratified_depths(count, lbl);
                std::vector<size_t> got;
                uint64_t gn = grind_and_sample_stratified_queries(ch, bits, lbl, count, depths, got);
                if (gn != en || got.size() != count) { printf("STRAT_QUERIES op %u FAIL (nonce/size)\n", op); return 1; }
                for (uint32_t i = 0; i < count; i++) if (got[i] != exp[i]) {
                    printf("STRAT_QUERIES op %u idx %u FAIL: got %zu exp %zu\n", op, i, got[i], exp[i]); return 1;
                }
                samples++; grinds++; break;
            }
            default: printf("bad op_type %u\n", t); return 1;
        }
    }
    fclose(f);
    printf("CHALLENGER OK: %u ops (%d samples + %d grinds) match the real FsChallenger byte-for-bit\n",
           n_ops, samples, grinds);
    return 0;
}
