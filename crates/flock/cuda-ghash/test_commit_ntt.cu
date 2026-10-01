// Bit-for-bit validation of the CUDA interleaved additive-NTT (P2) against the
// flare CPU oracle dumped by `src/bin/dump_commit_vectors.rs` (CMT1 format).
//
// Pipeline (mirrors src/pcs/commit.rs::commit_into -> finalize_commit):
//   1. replicate_message_fill: tile z_packed into the 2^log_inv_rate replicas
//      that the first log_inv_rate (pure-copy) NTT layers would produce.
//   2. forward interleaved NTT from layer log_inv_rate to k_code.
//   3. compare the device codeword to the golden post-NTT codeword.
//
// This validates the NTT kernel only; the Merkle root (also in the file) is P3.
//
// Build:  make test_commit_ntt
// Run:    (from repo root)
//           cargo run --release --bin dump_commit_vectors -- cuda-ghash/commit_vectors.bin 16 1 5
//         (from cuda-ghash/)
//           ./test_commit_ntt commit_vectors.bin
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include "ntt_f128.cuh"

#define CK(x) do { cudaError_t e=(x); if(e){ \
    printf("CUDA error %s at %s:%d\n", cudaGetErrorString(e), __FILE__, __LINE__); \
    exit(1);} } while(0)

static uint32_t rd_u32(FILE* f) {
    uint32_t v = 0;
    if (fread(&v, 4, 1, f) != 1) { printf("short read (u32)\n"); exit(1); }
    return v;
}

int main(int argc, char** argv) {
    const char* path = argc > 1 ? argv[1] : "commit_vectors.bin";
    FILE* f = fopen(path, "rb");
    if (!f) { printf("cannot open %s (run dump_commit_vectors first)\n", path); return 1; }

    uint32_t magic = rd_u32(f);
    if (magic != 0x434D5431u) { printf("bad file (magic=%08x, want CMT1)\n", magic); return 1; }
    uint32_t m              = rd_u32(f);
    uint32_t log_inv_rate   = rd_u32(f);
    uint32_t log_batch_size = rd_u32(f);
    uint32_t k_code         = rd_u32(f);
    uint32_t num_ntts       = rd_u32(f);
    uint32_t n_positions    = rd_u32(f);
    uint32_t n_leaves       = rd_u32(f);
    uint32_t leaf_size_bytes= rd_u32(f);
    uint32_t msg_len        = rd_u32(f);
    (void)log_batch_size; (void)n_leaves; (void)leaf_size_bytes;

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

    int log_d = (int)k_code;                  // per-lane NTT size (== L)
    size_t codeword_len = (size_t)n_positions * num_ntts;
    if (codeword_len != cw_len) {
        printf("inconsistent file: n_positions*num_ntts=%zu != cw_len=%u\n", codeword_len, cw_len);
        return 1;
    }
    printf("CMT1: m=%u rate=1/%u batch=%u k_code=%u num_ntts=%u positions=%u msg_len=%u cw_len=%u\n",
           m, 1u << log_inv_rate, log_batch_size, k_code, num_ntts, n_positions, msg_len, cw_len);

    // ---- Step 1: replicate_message_fill on the host (tile msg into codeword).
    if (codeword_len % msg_len != 0) { printf("cw_len not a multiple of msg_len\n"); return 1; }
    std::vector<F128> codeword(codeword_len);
    for (size_t i = 0; i < codeword_len; i++) codeword[i] = msg[i % msg_len];

    // ---- Twiddle table (host build), L = k_code.
    TwiddleTable tt = build_twiddle_table(log_d);

    F128* d_data = nullptr;
    F128* d_tw   = nullptr;
    CK(cudaMalloc(&d_data, codeword_len * sizeof(F128)));
    CK(cudaMalloc(&d_tw, tt.data.size() * sizeof(F128)));
    CK(cudaMemcpy(d_data, codeword.data(), codeword_len * sizeof(F128), cudaMemcpyHostToDevice));
    CK(cudaMemcpy(d_tw, tt.data.data(), tt.data.size() * sizeof(F128), cudaMemcpyHostToDevice));

    // ---- Step 2: forward interleaved NTT, layers [log_inv_rate, k_code).
    // Uses the fused launcher (fused-4 / fused-2 / single), same path as the
    // throughput bench, so this validates the fused kernels too.
    launch_ntt(d_data, d_tw, tt, (int)log_inv_rate, (int)k_code, (int)num_ntts);
    CK(cudaGetLastError());
    CK(cudaDeviceSynchronize());

    std::vector<F128> got(codeword_len);
    CK(cudaMemcpy(got.data(), d_data, codeword_len * sizeof(F128), cudaMemcpyDeviceToHost));

    // ---- Step 3: compare.
    size_t bad = 0, first = 0;
    for (size_t i = 0; i < codeword_len; i++) {
        if (got[i].lo != golden[i].lo || got[i].hi != golden[i].hi) {
            if (!bad) first = i;
            bad++;
        }
    }
    if (bad) {
        F128 g = got[first], e = golden[first];
        printf("NTT FAIL: %zu/%zu positions mismatch; first @%zu: got %016llx:%016llx exp %016llx:%016llx\n",
               bad, codeword_len, first, g.hi, g.lo, e.hi, e.lo);
        return 1;
    }
    printf("NTT OK: %zu/%zu codeword elements match flare bit-for-bit\n", codeword_len, codeword_len);
    cudaFree(d_data); cudaFree(d_tw);
    return 0;
}
