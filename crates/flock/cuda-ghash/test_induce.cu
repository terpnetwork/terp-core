// Bit-for-bit validation of the CUDA induce_sumcheck_poly (step 4 of the GPU
// pcs::open / Ligerito port against the flock CPU oracle
// dumped by `src/bin/dump_induce_vectors.rs` (INDC format) — sourced from the
// real `ligerito::induce_sumcheck_poly`.
//
// Loads inputs, runs host setup + the device accumulation, and compares the
// full basis_poly (length 2^log_msg_cols) AND enforced_sum bit-for-bit.
//
// Build:  make test_induce
// Run:    (from repo root)
//           cargo run --release --bin dump_induce_vectors -- cuda-ghash/induce_vectors.bin 10 2 8
//         (from cuda-ghash/)
//           ./test_induce induce_vectors.bin
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include "induce_sumcheck.cuh"

#define CK(x) do { cudaError_t e=(x); if(e){ \
    printf("CUDA error %s at %s:%d\n", cudaGetErrorString(e), __FILE__, __LINE__); \
    exit(1);} } while(0)

static uint32_t rd_u32(FILE* f) {
    uint32_t v = 0;
    if (fread(&v, 4, 1, f) != 1) { printf("short read (u32)\n"); exit(1); }
    return v;
}
static uint64_t rd_u64(FILE* f) {
    uint64_t v = 0;
    if (fread(&v, 8, 1, f) != 1) { printf("short read (u64)\n"); exit(1); }
    return v;
}
static F128 rd_f128(FILE* f) {
    u64 v[2];
    if (fread(v, 8, 2, f) != 2) { printf("short read (f128)\n"); exit(1); }
    return F128{v[0], v[1]};
}
static bool eq(F128 a, F128 b) { return a.lo == b.lo && a.hi == b.hi; }

int main(int argc, char** argv) {
    const char* path = argc > 1 ? argv[1] : "induce_vectors.bin";
    FILE* f = fopen(path, "rb");
    if (!f) { printf("cannot open %s (run dump_induce_vectors first)\n", path); return 1; }

    if (rd_u32(f) != 0x494E4443u) { printf("bad file (want INDC)\n"); return 1; }
    int log_n          = (int)rd_u32(f);
    int v_len          = (int)rd_u32(f);
    int num_interleaved= (int)rd_u32(f);
    int n_queries      = (int)rd_u32(f);
    int alpha_len      = (int)rd_u32(f);
    int sks_len        = (int)rd_u32(f);

    std::vector<F128> v_challenges(v_len), alpha(alpha_len), sks_vks(sks_len);
    for (int i = 0; i < v_len; i++) v_challenges[i] = rd_f128(f);
    for (int i = 0; i < alpha_len; i++) alpha[i] = rd_f128(f);
    for (int i = 0; i < sks_len; i++) sks_vks[i] = rd_f128(f);
    std::vector<unsigned long long> queries(n_queries);
    for (int i = 0; i < n_queries; i++) queries[i] = rd_u64(f);
    std::vector<F128> opened_rows((size_t)n_queries * num_interleaved);
    for (size_t i = 0; i < opened_rows.size(); i++) opened_rows[i] = rd_f128(f);

    uint32_t n = rd_u32(f);
    std::vector<F128> golden(n);
    for (uint32_t i = 0; i < n; i++) golden[i] = rd_f128(f);
    F128 gold_esum = rd_f128(f);
    fclose(f);

    printf("INDC: log_n=%d v_len=%d num_interleaved=%d n_queries=%d alpha_len=%d n=%u\n",
           log_n, v_len, num_interleaved, n_queries, alpha_len, n);

    // ---- host setup (faithful reimpl) ----
    InduceSetup S = induce_setup(log_n, sks_vks, v_challenges, alpha, queries,
                                 opened_rows, num_interleaved);
    if (S.n != (long long)n) { printf("n mismatch: %lld != %u\n", S.n, n); return 1; }

    if (!eq(S.enforced_sum, gold_esum)) {
        printf("ENFORCED_SUM FAIL: got %016llx:%016llx exp %016llx:%016llx\n",
               (unsigned long long)S.enforced_sum.hi, (unsigned long long)S.enforced_sum.lo,
               (unsigned long long)gold_esum.hi, (unsigned long long)gold_esum.lo);
        return 1;
    }

    // ---- device accumulation ----
    F128 *d_low, *d_sh, *d_basis;
    CK(cudaMalloc(&d_low, S.low.size() * sizeof(F128)));
    CK(cudaMalloc(&d_sh, S.scaled_high.size() * sizeof(F128)));
    CK(cudaMalloc(&d_basis, (size_t)n * sizeof(F128)));
    CK(cudaMemcpy(d_low, S.low.data(), S.low.size() * sizeof(F128), cudaMemcpyHostToDevice));
    CK(cudaMemcpy(d_sh, S.scaled_high.data(), S.scaled_high.size() * sizeof(F128), cudaMemcpyHostToDevice));

    launch_induce_accumulate(d_sh, d_low, S.n_queries, S.low_n, S.high_n, d_basis, n);
    CK(cudaGetLastError());
    CK(cudaDeviceSynchronize());

    std::vector<F128> got(n);
    CK(cudaMemcpy(got.data(), d_basis, (size_t)n * sizeof(F128), cudaMemcpyDeviceToHost));

    size_t bad = 0, first = 0;
    for (uint32_t i = 0; i < n; i++) {
        if (!eq(got[i], golden[i])) { if (!bad) first = i; bad++; }
    }
    if (bad) {
        F128 g = got[first], e = golden[first];
        printf("BASIS FAIL: %zu/%u mismatch; first @%zu: got %016llx:%016llx exp %016llx:%016llx\n",
               bad, n, first,
               (unsigned long long)g.hi, (unsigned long long)g.lo,
               (unsigned long long)e.hi, (unsigned long long)e.lo);
        return 1;
    }

    printf("INDUCE OK: enforced_sum + all %u basis_poly elements match flock bit-for-bit\n", n);
    cudaFree(d_low); cudaFree(d_sh); cudaFree(d_basis);
    return 0;
}
