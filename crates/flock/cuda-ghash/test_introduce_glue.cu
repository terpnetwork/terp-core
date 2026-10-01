// Bit-for-bit validation of the CUDA introduce_new + glue (step 5 of the GPU
// pcs::open / Ligerito port against the flock CPU oracle
// dumped by `src/bin/dump_introduce_glue_vectors.rs` (INGL format) — message +
// h_new sourced from the real `SumcheckProver::introduce_new_with_eval`.
//
// Checks: the introduce message {u_0, u_2}, the eval h_new = Σ f·b_new, and the
// glued combined_basis (b1 + β·b_new), all bit-for-bit.
//
// Build:  make test_introduce_glue
// Run:    (repo root)  cargo run --release --bin dump_introduce_glue_vectors -- cuda-ghash/introduce_glue_vectors.bin 12
//         (cuda-ghash) ./test_introduce_glue introduce_glue_vectors.bin
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include "introduce_glue.cuh"

#define CK(x) do { cudaError_t e=(x); if(e){ \
    printf("CUDA error %s at %s:%d\n", cudaGetErrorString(e), __FILE__, __LINE__); \
    exit(1);} } while(0)

static uint32_t rd_u32(FILE* f) {
    uint32_t v = 0;
    if (fread(&v, 4, 1, f) != 1) { printf("short read\n"); exit(1); }
    return v;
}
static F128 rd_f128(FILE* f) {
    u64 v[2];
    if (fread(v, 8, 2, f) != 2) { printf("short read (f128)\n"); exit(1); }
    return F128{v[0], v[1]};
}
static bool eq(F128 a, F128 b) { return a.lo == b.lo && a.hi == b.hi; }
static void show(const char* tag, F128 g, F128 e) {
    printf("%s got %016llx:%016llx exp %016llx:%016llx\n", tag,
           (unsigned long long)g.hi, (unsigned long long)g.lo,
           (unsigned long long)e.hi, (unsigned long long)e.lo);
}

int main(int argc, char** argv) {
    const char* path = argc > 1 ? argv[1] : "introduce_glue_vectors.bin";
    FILE* fp = fopen(path, "rb");
    if (!fp) { printf("cannot open %s (run dump_introduce_glue_vectors first)\n", path); return 1; }

    if (rd_u32(fp) != 0x494E474Cu) { printf("bad file (want INGL)\n"); return 1; }
    int log_len = (int)rd_u32(fp);
    uint32_t len = rd_u32(fp);
    std::vector<F128> f(len), b1(len), b_new(len);
    for (uint32_t i = 0; i < len; i++) f[i] = rd_f128(fp);
    for (uint32_t i = 0; i < len; i++) b1[i] = rd_f128(fp);
    for (uint32_t i = 0; i < len; i++) b_new[i] = rd_f128(fp);
    F128 beta = rd_f128(fp), gu0 = rd_f128(fp), gu2 = rd_f128(fp), ghnew = rd_f128(fp);
    std::vector<F128> gcb(len);
    for (uint32_t i = 0; i < len; i++) gcb[i] = rd_f128(fp);
    fclose(fp);

    printf("INGL: log_len=%d len=%u\n", log_len, len);

    F128 *dF, *dB, *dCB;
    F128 *d_p0, *d_p2, *d_podd;
    F128 *d_u0, *d_u2, *d_hnew;
    CK(cudaMalloc(&dF, (size_t)len * sizeof(F128)));
    CK(cudaMalloc(&dB, (size_t)len * sizeof(F128)));
    CK(cudaMalloc(&dCB, (size_t)len * sizeof(F128)));
    CK(cudaMalloc(&d_p0, IGL_MAX_BLOCKS * sizeof(F128)));
    CK(cudaMalloc(&d_p2, IGL_MAX_BLOCKS * sizeof(F128)));
    CK(cudaMalloc(&d_podd, IGL_MAX_BLOCKS * sizeof(F128)));
    CK(cudaMalloc(&d_u0, sizeof(F128)));
    CK(cudaMalloc(&d_u2, sizeof(F128)));
    CK(cudaMalloc(&d_hnew, sizeof(F128)));
    CK(cudaMemcpy(dF, f.data(), (size_t)len * sizeof(F128), cudaMemcpyHostToDevice));
    CK(cudaMemcpy(dB, b_new.data(), (size_t)len * sizeof(F128), cudaMemcpyHostToDevice));
    CK(cudaMemcpy(dCB, b1.data(), (size_t)len * sizeof(F128), cudaMemcpyHostToDevice)); // cb starts as b1

    // --- introduce: message + h_new over (f, b_new)
    launch_basis_message_evaluation(dF, dB, (long long)len / 2, d_p0, d_p2, d_podd, d_u0, d_u2, d_hnew);
    CK(cudaGetLastError());
    F128 u0, u2, hnew;
    CK(cudaMemcpy(&u0, d_u0, sizeof(F128), cudaMemcpyDeviceToHost));
    CK(cudaMemcpy(&u2, d_u2, sizeof(F128), cudaMemcpyDeviceToHost));
    CK(cudaMemcpy(&hnew, d_hnew, sizeof(F128), cudaMemcpyDeviceToHost));
    if (!eq(u0, gu0) || !eq(u2, gu2) || !eq(hnew, ghnew)) {
        printf("INTRODUCE FAIL:\n");
        show("  u_0  ", u0, gu0); show("  u_2  ", u2, gu2); show("  h_new", hnew, ghnew);
        return 1;
    }

    // --- glue: cb (= b1) += beta * b_new
    launch_glue(dCB, dB, beta, (long long)len);
    CK(cudaGetLastError());
    CK(cudaDeviceSynchronize());
    std::vector<F128> cb(len);
    CK(cudaMemcpy(cb.data(), dCB, (size_t)len * sizeof(F128), cudaMemcpyDeviceToHost));
    size_t bad = 0, first = 0;
    for (uint32_t i = 0; i < len; i++) if (!eq(cb[i], gcb[i])) { if (!bad) first = i; bad++; }
    if (bad) {
        printf("GLUE FAIL: %zu/%u mismatch; first @%zu:\n", bad, len, first);
        show("  cb", cb[first], gcb[first]);
        return 1;
    }

    printf("INTRODUCE+GLUE OK: msg {u_0,u_2}, h_new, and glued basis (%u elems) match flock bit-for-bit\n", len);
    cudaFree(dF); cudaFree(dB); cudaFree(dCB);
    cudaFree(d_p0); cudaFree(d_p2); cudaFree(d_podd);
    cudaFree(d_u0); cudaFree(d_u2); cudaFree(d_hnew);
    return 0;
}
