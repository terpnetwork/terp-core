// Bit-for-bit validation of the CUDA BLAKE3 witness generator against the flock
// CPU oracle dumped by src/bin/dump_blake3_witness_vectors.rs (B3WT format).
//
// Loads the same Compression inputs, runs blake3_witness_blocks (→ z/a/b) and
// blake3_lincheck_transpose (→ z_lincheck), and asserts all four outputs
// bit-for-bit vs the real generate_witness_with_ab_packed_and_lincheck.
//
// Build:  make test_blake3_witness
// Run:    (repo root) cargo run --release --bin dump_blake3_witness_vectors -- cuda-ghash/blake3_witness_vectors.bin 24 5
//         (cuda-ghash/) ./test_blake3_witness blake3_witness_vectors.bin
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include "blake3_witness.cuh"

#define CK(x) do { cudaError_t e=(x); if(e){ \
    printf("CUDA error %s at %s:%d\n", cudaGetErrorString(e), __FILE__, __LINE__); \
    exit(1);} } while(0)

static uint32_t rd_u32(FILE* f) { uint32_t v=0; if(fread(&v,4,1,f)!=1){printf("short u32\n");exit(1);} return v; }
static b3u64   rd_u64(FILE* f) { b3u64 v=0;   if(fread(&v,8,1,f)!=1){printf("short u64\n");exit(1);} return v; }

static int cmp_u64(const char* name, const std::vector<b3u64>& got, const std::vector<b3u64>& exp) {
    for (size_t i = 0; i < exp.size(); i++) {
        if (got[i] != exp[i]) {
            printf("%s FAIL at u64 %zu (block %zu word %zu): got %016llx exp %016llx\n",
                   name, i, i / B3_U64_PER_BLOCK, i % B3_U64_PER_BLOCK,
                   (unsigned long long)got[i], (unsigned long long)exp[i]);
            return 1;
        }
    }
    printf("  %-12s OK (%zu u64)\n", name, exp.size());
    return 0;
}

int main(int argc, char** argv) {
    const char* path = argc > 1 ? argv[1] : "blake3_witness_vectors.bin";
    FILE* f = fopen(path, "rb");
    if (!f) { printf("cannot open %s (run dump_blake3_witness_vectors first)\n", path); return 1; }

    if (rd_u32(f) != 0x42335754u) { printf("bad file (want B3WT magic)\n"); return 1; }
    int n_blocks_log = (int)rd_u32(f);
    int n_blocks = (int)rd_u32(f);
    int k_log = (int)rd_u32(f);
    if (k_log != B3_K_LOG) { printf("k_log %d != %d\n", k_log, B3_K_LOG); return 1; }
    long long n_total = 1LL << n_blocks_log;
    long long u64_total = n_total * B3_U64_PER_BLOCK;
    long long lincheck_bytes = (n_total / 8) * (long long)B3_K;

    // Inputs (SoA).
    std::vector<uint32_t> cv(n_blocks * 8), m(n_blocks * 16), blen(n_blocks), flags(n_blocks);
    std::vector<b3u64> ctr(n_blocks);
    for (int blk = 0; blk < n_blocks; blk++) {
        for (int w = 0; w < 8; w++) cv[blk * 8 + w] = rd_u32(f);
        for (int i = 0; i < 16; i++) m[blk * 16 + i] = rd_u32(f);
        ctr[blk] = rd_u64(f);
        blen[blk] = rd_u32(f);
        flags[blk] = rd_u32(f);
    }
    // Golden outputs.
    std::vector<b3u64> gz(u64_total), ga(u64_total), gb(u64_total);
    for (auto& v : gz) v = rd_u64(f);
    for (auto& v : ga) v = rd_u64(f);
    for (auto& v : gb) v = rd_u64(f);
    std::vector<uint8_t> glin(lincheck_bytes);
    if ((long long)fread(glin.data(), 1, lincheck_bytes, f) != lincheck_bytes) { printf("short z_lincheck\n"); return 1; }
    fclose(f);

    printf("B3WT: n_blocks=%d n_blocks_log=%d n_total=%lld m=%d k_log=%d\n",
           n_blocks, n_blocks_log, n_total, B3_K_LOG + n_blocks_log, k_log);

    // Device buffers.
    uint32_t *d_cv, *d_m, *d_blen, *d_flags;
    b3u64 *d_ctr, *d_z, *d_a, *d_b;
    uint8_t* d_lin;
    CK(cudaMalloc(&d_cv, cv.size() * 4));
    CK(cudaMalloc(&d_m, m.size() * 4));
    CK(cudaMalloc(&d_blen, blen.size() * 4));
    CK(cudaMalloc(&d_flags, flags.size() * 4));
    CK(cudaMalloc(&d_ctr, ctr.size() * 8));
    CK(cudaMalloc(&d_z, u64_total * 8));
    CK(cudaMalloc(&d_a, u64_total * 8));
    CK(cudaMalloc(&d_b, u64_total * 8));
    CK(cudaMalloc(&d_lin, lincheck_bytes));
    CK(cudaMemcpy(d_cv, cv.data(), cv.size() * 4, cudaMemcpyHostToDevice));
    CK(cudaMemcpy(d_m, m.data(), m.size() * 4, cudaMemcpyHostToDevice));
    CK(cudaMemcpy(d_blen, blen.data(), blen.size() * 4, cudaMemcpyHostToDevice));
    CK(cudaMemcpy(d_flags, flags.data(), flags.size() * 4, cudaMemcpyHostToDevice));
    CK(cudaMemcpy(d_ctr, ctr.data(), ctr.size() * 8, cudaMemcpyHostToDevice));

    // Pre-zero z/a/b (the per-block builder ORs into pre-zeroed words; padding
    // blocks must read as zero for the transpose).
    CK(cudaMemset(d_z, 0, u64_total * 8));
    CK(cudaMemset(d_a, 0, u64_total * 8));
    CK(cudaMemset(d_b, 0, u64_total * 8));

    launch_blake3_witness_blocks(d_cv, d_m, d_ctr, d_blen, d_flags, n_blocks, n_total, d_z, d_a, d_b);
    CK(cudaGetLastError());
    launch_blake3_lincheck_transpose(d_z, n_total, d_lin);
    CK(cudaGetLastError());
    CK(cudaDeviceSynchronize());

    std::vector<b3u64> z(u64_total), a(u64_total), b(u64_total);
    std::vector<uint8_t> lin(lincheck_bytes);
    CK(cudaMemcpy(z.data(), d_z, u64_total * 8, cudaMemcpyDeviceToHost));
    CK(cudaMemcpy(a.data(), d_a, u64_total * 8, cudaMemcpyDeviceToHost));
    CK(cudaMemcpy(b.data(), d_b, u64_total * 8, cudaMemcpyDeviceToHost));
    CK(cudaMemcpy(lin.data(), d_lin, lincheck_bytes, cudaMemcpyDeviceToHost));

    int rc = 0;
    rc |= cmp_u64("z", z, gz);
    rc |= cmp_u64("a", a, ga);
    rc |= cmp_u64("b", b, gb);
    for (long long i = 0; i < lincheck_bytes; i++) {
        if (lin[i] != glin[i]) {
            printf("z_lincheck FAIL at byte %lld: got %02x exp %02x\n", i, lin[i], glin[i]);
            rc = 1; break;
        }
    }
    if (!rc) printf("  %-12s OK (%lld bytes)\n", "z_lincheck", lincheck_bytes);
    if (rc) return 1;

    printf("BLAKE3 WITNESS OK: z + a + b + z_lincheck match flock bit-for-bit\n");
    return 0;
}
