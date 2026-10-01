// Bit-for-bit validation of the CUDA a·b multilinear sumcheck (step 3 of the
// GPU pcs::open / Ligerito port against the flock CPU oracle
// dumped by `src/bin/dump_sumcheck_vectors.rs` (SMC1 format).
//
// Pipeline (mirrors the CPU a·b sumcheck — `ligerito.rs`'s `fold_and_msg_lsb`
// message/fold convention): per round, over the
// current a,b, compute the {0,∞} message (u_0, u_2) via deferred reduction and
// compare to the oracle; then fold a,b by the oracle's challenge r_k. After L
// rounds, compare the length-1 final_a / final_b. Both the per-round messages
// AND the folded tables are checked, every round.
//
// Build:  make test_sumcheck_ab
// Run:    (from repo root)
//           cargo run --release --bin dump_sumcheck_vectors -- cuda-ghash/sumcheck_vectors.bin 12
//         (from cuda-ghash/)
//           ./test_sumcheck_ab sumcheck_vectors.bin
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include "sumcheck_ab.cuh"

#define CK(x) do { cudaError_t e=(x); if(e){ \
    printf("CUDA error %s at %s:%d\n", cudaGetErrorString(e), __FILE__, __LINE__); \
    exit(1);} } while(0)

static uint32_t rd_u32(FILE* f) {
    uint32_t v = 0;
    if (fread(&v, 4, 1, f) != 1) { printf("short read (u32)\n"); exit(1); }
    return v;
}
static F128 rd_f128(FILE* f) {
    u64 v[2];
    if (fread(v, 8, 2, f) != 2) { printf("short read (f128)\n"); exit(1); }
    return F128{v[0], v[1]};
}
static bool eq(F128 a, F128 b) { return a.lo == b.lo && a.hi == b.hi; }

int main(int argc, char** argv) {
    const char* path = argc > 1 ? argv[1] : "sumcheck_vectors.bin";
    FILE* f = fopen(path, "rb");
    if (!f) { printf("cannot open %s (run dump_sumcheck_vectors first)\n", path); return 1; }

    uint32_t magic = rd_u32(f);
    if (magic != 0x534D4331u) { printf("bad file (magic=%08x, want SMC1)\n", magic); return 1; }
    int log_len = (int)rd_u32(f);
    uint32_t init_len = rd_u32(f);
    if (init_len != (1u << log_len)) { printf("init_len %u != 2^L\n", init_len); return 1; }

    std::vector<F128> a(init_len), b(init_len);
    for (uint32_t i = 0; i < init_len; i++) a[i] = rd_f128(f);
    for (uint32_t i = 0; i < init_len; i++) b[i] = rd_f128(f);

    printf("SMC1: log_len=%d init_len=%u rounds=%d\n", log_len, init_len, log_len);

    // Ping-pong device buffers (init_len is the max size).
    F128 *dA = nullptr, *dB = nullptr, *dAn = nullptr, *dBn = nullptr;
    F128 *d_p0 = nullptr, *d_p2 = nullptr;
    F128 *d_u0 = nullptr, *d_u2 = nullptr;
    CK(cudaMalloc(&dA, (size_t)init_len * sizeof(F128)));
    CK(cudaMalloc(&dB, (size_t)init_len * sizeof(F128)));
    CK(cudaMalloc(&dAn, (size_t)init_len * sizeof(F128)));
    CK(cudaMalloc(&dBn, (size_t)init_len * sizeof(F128)));
    CK(cudaMalloc(&d_p0, SMC_MAX_BLOCKS * sizeof(F128)));
    CK(cudaMalloc(&d_p2, SMC_MAX_BLOCKS * sizeof(F128)));
    CK(cudaMalloc(&d_u0, sizeof(F128)));
    CK(cudaMalloc(&d_u2, sizeof(F128)));
    CK(cudaMemcpy(dA, a.data(), (size_t)init_len * sizeof(F128), cudaMemcpyHostToDevice));
    CK(cudaMemcpy(dB, b.data(), (size_t)init_len * sizeof(F128), cudaMemcpyHostToDevice));

    long long len = init_len;
    F128 *cA = dA, *cB = dB, *nA = dAn, *nB = dBn;

    for (int k = 0; k < log_len; k++) {
        long long half = len / 2;
        // --- message
        launch_sumcheck_message(cA, cB, half, d_p0, d_p2, d_u0, d_u2);
        CK(cudaGetLastError());
        F128 u0, u2;
        CK(cudaMemcpy(&u0, d_u0, sizeof(F128), cudaMemcpyDeviceToHost));
        CK(cudaMemcpy(&u2, d_u2, sizeof(F128), cudaMemcpyDeviceToHost));

        // --- oracle round record
        F128 r  = rd_f128(f);
        F128 gu0 = rd_f128(f);
        F128 gu2 = rd_f128(f);
        if (!eq(u0, gu0) || !eq(u2, gu2)) {
            printf("MSG FAIL round %d: u_0 got %016llx:%016llx exp %016llx:%016llx | "
                   "u_2 got %016llx:%016llx exp %016llx:%016llx\n", k,
                   (unsigned long long)u0.hi, (unsigned long long)u0.lo,
                   (unsigned long long)gu0.hi, (unsigned long long)gu0.lo,
                   (unsigned long long)u2.hi, (unsigned long long)u2.lo,
                   (unsigned long long)gu2.hi, (unsigned long long)gu2.lo);
            return 1;
        }

        // --- fold by r
        launch_sumcheck_fold(cA, cB, nA, nB, half, r);
        CK(cudaGetLastError());
        CK(cudaDeviceSynchronize());
        F128* t;
        t = cA; cA = nA; nA = t;
        t = cB; cB = nB; nB = t;
        len = half;
        printf("  round %2d  len %8lld -> %8lld  msg OK\n", k, len * 2, len);
    }

    // --- final folded values
    F128 fa, fb;
    CK(cudaMemcpy(&fa, cA, sizeof(F128), cudaMemcpyDeviceToHost));
    CK(cudaMemcpy(&fb, cB, sizeof(F128), cudaMemcpyDeviceToHost));
    F128 gfa = rd_f128(f), gfb = rd_f128(f);
    fclose(f);
    if (!eq(fa, gfa) || !eq(fb, gfb)) {
        printf("FINAL FAIL: a got %016llx:%016llx exp %016llx:%016llx | "
               "b got %016llx:%016llx exp %016llx:%016llx\n",
               (unsigned long long)fa.hi, (unsigned long long)fa.lo,
               (unsigned long long)gfa.hi, (unsigned long long)gfa.lo,
               (unsigned long long)fb.hi, (unsigned long long)fb.lo,
               (unsigned long long)gfb.hi, (unsigned long long)gfb.lo);
        return 1;
    }

    printf("SUMCHECK OK: all %d rounds' messages + folds + final a,b match flock bit-for-bit\n",
           log_len);
    cudaFree(dA); cudaFree(dB); cudaFree(dAn); cudaFree(dBn);
    cudaFree(d_p0); cudaFree(d_p2); cudaFree(d_u0); cudaFree(d_u2);
    return 0;
}
