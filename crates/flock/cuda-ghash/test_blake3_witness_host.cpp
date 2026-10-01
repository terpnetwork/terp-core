// Host-side validation of the blake3_witness.cuh trace builder against the
// real Rust generator's B3WT oracle (dump_blake3_witness_vectors) — no GPU,
// no nvcc. Runs the serial b3_build_trace per (block, slice) + the stripe
// transpose and compares every u64 / byte. Catches witness-LAYOUT drift
// locally before it costs a Blackwell CI run; the device kernels share the
// same b3_g_update, so a pass here plus the (GPU) blake3_witness target
// covers both.
//
// Build:  make test_blake3_witness_host   (plain host C++)
// Run:    (repo root) cargo run --release --bin dump_blake3_witness_vectors -- cuda-ghash/blake3_witness_vectors.bin 24 5
//         (cuda-ghash) ./test_blake3_witness_host blake3_witness_vectors.bin
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>
#include "blake3_witness.cuh"

static uint32_t rd_u32(FILE* f) { uint32_t v; if (fread(&v, 4, 1, f) != 1) { printf("short u32\n"); exit(1); } return v; }
static uint64_t rd_u64(FILE* f) { uint64_t v; if (fread(&v, 8, 1, f) != 1) { printf("short u64\n"); exit(1); } return v; }

int main(int argc, char** argv) {
    const char* path = argc > 1 ? argv[1] : "blake3_witness_vectors.bin";
    FILE* f = fopen(path, "rb");
    if (!f) { printf("cannot open %s\n", path); return 1; }
    if (rd_u32(f) != 0x42335754u) { printf("bad magic\n"); return 1; }
    int n_blocks_log = (int)rd_u32(f);
    int n_blocks = (int)rd_u32(f);
    int k_log = (int)rd_u32(f);
    if (k_log != B3_K_LOG) { printf("k_log %d != %d\n", k_log, B3_K_LOG); return 1; }
    long long n_total = 1LL << n_blocks_log;

    struct Cmp { uint32_t cv[8], m[16]; uint64_t ctr; uint32_t blen, flags; };
    std::vector<Cmp> blocks(n_blocks);
    for (auto& b : blocks) {
        for (auto& x : b.cv) x = rd_u32(f);
        for (auto& x : b.m) x = rd_u32(f);
        b.ctr = rd_u64(f);
        b.blen = rd_u32(f);
        b.flags = rd_u32(f);
    }

    long long u64_total = n_total * B3_U64_PER_BLOCK;
    std::vector<uint64_t> ez(u64_total), ea(u64_total), eb(u64_total);
    if (fread(ez.data(), 8, u64_total, f) != (size_t)u64_total) { printf("short z\n"); return 1; }
    if (fread(ea.data(), 8, u64_total, f) != (size_t)u64_total) { printf("short a\n"); return 1; }
    if (fread(eb.data(), 8, u64_total, f) != (size_t)u64_total) { printf("short b\n"); return 1; }
    long long lb_bytes = (n_total / 8) * (long long)B3_K;
    std::vector<uint8_t> elc(lb_bytes);
    if (fread(elc.data(), 1, lb_bytes, f) != (size_t)lb_bytes) { printf("short z_lincheck\n"); return 1; }
    fclose(f);

    printf("B3WT: n_blocks=%d n_total=%lld k_log=%d\n", n_blocks, n_total, k_log);

    const uint64_t* exp3[3] = {ez.data(), ea.data(), eb.data()};
    const char* names[3] = {"z", "a", "b"};
    std::vector<uint64_t> gz(u64_total);   // keep computed z for the transpose check
    int bad = 0;
    for (long long blk = 0; blk < n_total && bad < 8; blk++) {
        Cmp pad{};
        const Cmp& c = (blk < n_blocks) ? blocks[blk] : pad;
        for (int which = 0; which < 3; which++) {
            b3u64 buf[B3_U64_PER_BLOCK];
            memset(buf, 0, sizeof buf);
            b3_build_trace(buf, which, c.cv, c.m, (uint32_t)c.ctr, (uint32_t)(c.ctr >> 32),
                           c.blen, c.flags);
            if (which == 0) memcpy(&gz[blk * B3_U64_PER_BLOCK], buf, sizeof buf);
            const uint64_t* e = exp3[which] + blk * B3_U64_PER_BLOCK;
            for (int i = 0; i < B3_U64_PER_BLOCK; i++) {
                if (buf[i] != e[i]) {
                    printf("%s FAIL blk %lld word %d (bits %d..%d): got %016llx exp %016llx\n",
                           names[which], blk, i, i * 64, i * 64 + 63,
                           (unsigned long long)buf[i], (unsigned long long)e[i]);
                    if (++bad >= 8) break;
                }
            }
        }
    }
    if (bad) { printf("TRACE MISMATCHES: %d (stopping)\n", bad); return 1; }
    printf("traces OK: all %lld blocks x 3 slices match the Rust generator bit-for-bit\n", n_total);

    // lincheck stripe transpose (host replica of blake3_lincheck_transpose)
    for (long long g = 0; g < n_total / 8; g++) {
        for (int i = 0; i < B3_U64_PER_BLOCK; i++) {
            b3u64 lanes[8];
            for (int lane = 0; lane < 8; lane++)
                lanes[lane] = gz[(8 * g + lane) * B3_U64_PER_BLOCK + i];
            uint64_t out[8];
            for (int bc = 0; bc < 8; bc++) {
                b3u64 src = 0;
                for (int r = 0; r < 8; r++)
                    src |= ((lanes[r] >> (8 * bc)) & 0xFFull) << (8 * r);
                out[bc] = b3_transpose8(src);
            }
            const uint8_t* e = elc.data() + g * (long long)B3_K + (long long)i * 64;
            if (memcmp(out, e, 64) != 0) {
                printf("z_lincheck FAIL group %lld word %d\n", g, i);
                return 1;
            }
        }
    }
    printf("z_lincheck OK: stripe transpose matches\n");
    printf("BLAKE3 WITNESS HOST CHECK OK\n");
    return 0;
}
