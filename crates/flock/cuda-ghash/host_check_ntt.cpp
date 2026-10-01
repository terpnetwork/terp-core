// CPU validation of the interleaved additive-NTT twiddle schedule + butterfly
// against the flare oracle (CMT1, from src/bin/dump_commit_vectors.rs). This is
// a pure-host build (g++, no CUDA) so the *math* — the one correctness risk in
// the GPU port — can be checked on any machine before the Blackwell box runs
// the actual kernel. The CUDA kernel (ntt_f128.cuh) reuses the exact same
// twiddle table (ntt_host.hpp) and butterfly formula, so a pass here means the
// GPU port only has to get the launch mechanics + clmad right.
//
// Build:  g++ -O2 -std=c++17 host_check_ntt.cpp -o host_check_ntt
// Run:    ./host_check_ntt commit_vectors.bin
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>

typedef unsigned long long u64;
struct F128 { u64 lo, hi; };

#include "ntt_host.hpp"

static uint32_t rd_u32(FILE* f) {
    uint32_t v = 0;
    if (fread(&v, 4, 1, f) != 1) { printf("short read (u32)\n"); exit(1); }
    return v;
}

int main(int argc, char** argv) {
    const char* path = argc > 1 ? argv[1] : "commit_vectors.bin";
    FILE* f = fopen(path, "rb");
    if (!f) { printf("cannot open %s (run dump_commit_vectors first)\n", path); return 1; }

    if (rd_u32(f) != 0x434D5431u) { printf("bad file (want CMT1 magic)\n"); return 1; }
    uint32_t m              = rd_u32(f);
    uint32_t log_inv_rate   = rd_u32(f);
    uint32_t log_batch_size = rd_u32(f);
    uint32_t k_code         = rd_u32(f);
    uint32_t num_ntts       = rd_u32(f);
    uint32_t n_positions    = rd_u32(f);
    (void)rd_u32(f);  // n_leaves
    (void)rd_u32(f);  // leaf_size_bytes
    uint32_t msg_len        = rd_u32(f);

    std::vector<F128> msg(msg_len);
    for (uint32_t i = 0; i < msg_len; i++) {
        u64 v[2];
        if (fread(v, 8, 2, f) != 2) { printf("short read (msg @%u)\n", i); return 1; }
        msg[i] = F128{v[0], v[1]};
    }
    uint32_t cw_len = rd_u32(f);
    std::vector<F128> golden(cw_len);
    for (uint32_t i = 0; i < cw_len; i++) {
        u64 v[2];
        if (fread(v, 8, 2, f) != 2) { printf("short read (cw @%u)\n", i); return 1; }
        golden[i] = F128{v[0], v[1]};
    }
    fclose(f);

    int log_d = (int)k_code;
    size_t codeword_len = (size_t)n_positions * num_ntts;
    if (codeword_len != cw_len) { printf("inconsistent file\n"); return 1; }
    printf("CMT1: m=%u rate=1/%u batch=%u k_code=%u num_ntts=%u positions=%u cw_len=%u\n",
           m, 1u << log_inv_rate, log_batch_size, k_code, num_ntts, n_positions, cw_len);

    // Step 1: replicate_message_fill — tile msg into codeword.
    if (codeword_len % msg_len != 0) { printf("cw_len not a multiple of msg_len\n"); return 1; }
    std::vector<F128> cw(codeword_len);
    for (size_t i = 0; i < codeword_len; i++) cw[i] = msg[i % msg_len];

    // Step 2: scalar interleaved forward NTT, layers [log_inv_rate, k_code).
    TwiddleTable tt = build_twiddle_table(log_d);
    for (int layer = (int)log_inv_rate; layer < log_d; layer++) {
        long long num_blocks      = 1LL << layer;
        long long block_size      = 1LL << (log_d - layer);
        long long half            = block_size >> 1;
        long long block_size_elts = block_size * num_ntts;
        for (long long block = 0; block < num_blocks; block++) {
            F128 tw = twiddle_from_table(tt, layer, block);
            long long block_start = block * block_size_elts;
            for (long long row = 0; row < half; row++) {
                long long off_top = block_start + row * num_ntts;
                long long off_bot = off_top + half * num_ntts;
                for (long long lane = 0; lane < num_ntts; lane++) {
                    F128 v = cw[off_bot + lane];
                    F128 u = f128_add_hd(cw[off_top + lane], f128_mul_hd(v, tw));
                    cw[off_top + lane] = u;
                    cw[off_bot + lane] = f128_add_hd(v, u);
                }
            }
        }
    }

    // Step 3: compare.
    size_t bad = 0, first = 0;
    for (size_t i = 0; i < codeword_len; i++)
        if (cw[i].lo != golden[i].lo || cw[i].hi != golden[i].hi) { if (!bad) first = i; bad++; }
    if (bad) {
        F128 g = cw[first], e = golden[first];
        printf("NTT FAIL: %zu/%zu mismatch; first @%zu: got %016llx:%016llx exp %016llx:%016llx\n",
               bad, codeword_len, first, g.hi, g.lo, e.hi, e.lo);
        return 1;
    }
    printf("NTT OK: %zu/%zu codeword elements match flare bit-for-bit\n", codeword_len, codeword_len);
    return 0;
}
