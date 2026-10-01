// Composed device-resident SumcheckProver — step 6 milestone of the GPU
// pcs::open (Ligerito) port. Validates the full Ligerito
// sumcheck state machine (src/pcs/ligerito.rs::SumcheckProver) run entirely on
// device — (f, combined_basis) stay in VRAM across the whole run; only the small
// {u_0,u_2} messages cross to host. Drives a scripted op sequence (fold |
// introduce+glue) dumped from the REAL SumcheckProver and asserts the full
// message transcript + final f match bit-for-bit.
//
// Composes the validated kernels: sumcheck_msg + sumcheck_fold (step 3) and
// combine_basis_polynomials (step 5). The introduce message is round_msg_lsb(f, b_new) — the
// same {u_0,u_2} the sumcheck_msg kernel computes.
//
// Build:  make test_sumcheck_prover
// Run:    (repo root)  cargo run --release --bin dump_sumcheck_prover_vectors -- cuda-ghash/sumcheck_prover_vectors.bin 14
//         (cuda-ghash) ./test_sumcheck_prover sumcheck_prover_vectors.bin
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include "sumcheck_ab.cuh"
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

// Run the message kernel over (A,B) of length `len` and return (u_0,u_2).
static void dev_msg(const F128* A, const F128* B, long long len,
                    F128* p0, F128* p2, F128* du0, F128* du2, F128& u0, F128& u2) {
    launch_sumcheck_message(A, B, len / 2, p0, p2, du0, du2);
    CK(cudaGetLastError());
    CK(cudaMemcpy(&u0, du0, sizeof(F128), cudaMemcpyDeviceToHost));
    CK(cudaMemcpy(&u2, du2, sizeof(F128), cudaMemcpyDeviceToHost));
}

int main(int argc, char** argv) {
    const char* path = argc > 1 ? argv[1] : "sumcheck_prover_vectors.bin";
    FILE* fp = fopen(path, "rb");
    if (!fp) { printf("cannot open %s (run dump_sumcheck_prover_vectors first)\n", path); return 1; }

    if (rd_u32(fp) != 0x53435056u) { printf("bad file (want SCPV)\n"); return 1; }
    int log_len = (int)rd_u32(fp);
    uint32_t len0 = rd_u32(fp);
    std::vector<F128> f(len0), b1(len0);
    for (uint32_t i = 0; i < len0; i++) f[i] = rd_f128(fp);
    for (uint32_t i = 0; i < len0; i++) b1[i] = rd_f128(fp);
    F128 gmsg0_u0 = rd_f128(fp), gmsg0_u2 = rd_f128(fp);
    uint32_t n_ops = rd_u32(fp);

    printf("SCPV: log_len=%d len=%u n_ops=%u\n", log_len, len0, n_ops);

    // Resident state: ping-pong (f,cb) + a b_new staging buffer + msg scratch.
    F128 *df, *dcb, *df2, *dcb2, *dbnew, *du0, *du2;
    F128 *p0, *p2;
    CK(cudaMalloc(&df, (size_t)len0 * sizeof(F128)));
    CK(cudaMalloc(&dcb, (size_t)len0 * sizeof(F128)));
    CK(cudaMalloc(&df2, (size_t)len0 * sizeof(F128)));
    CK(cudaMalloc(&dcb2, (size_t)len0 * sizeof(F128)));
    CK(cudaMalloc(&dbnew, (size_t)len0 * sizeof(F128)));
    CK(cudaMalloc(&p0, SMC_MAX_BLOCKS * sizeof(F128)));
    CK(cudaMalloc(&p2, SMC_MAX_BLOCKS * sizeof(F128)));
    CK(cudaMalloc(&du0, sizeof(F128)));
    CK(cudaMalloc(&du2, sizeof(F128)));
    CK(cudaMemcpy(df, f.data(), (size_t)len0 * sizeof(F128), cudaMemcpyHostToDevice));
    CK(cudaMemcpy(dcb, b1.data(), (size_t)len0 * sizeof(F128), cudaMemcpyHostToDevice));

    F128 *cf = df, *ccb = dcb, *nf = df2, *ncb = dcb2;
    long long len = len0;

    // msg_0 over the initial (f, b1).
    F128 u0, u2;
    dev_msg(cf, ccb, len, p0, p2, du0, du2, u0, u2);
    if (!eq(u0, gmsg0_u0) || !eq(u2, gmsg0_u2)) { printf("MSG0 FAIL\n"); return 1; }

    std::vector<F128> bnew_host;
    for (uint32_t op = 0; op < n_ops; op++) {
        uint32_t op_type = rd_u32(fp);
        if (op_type == 0) {
            // fold(r): fold (f,cb) by r, then message over the folded pair.
            F128 r = rd_f128(fp);
            F128 gu0 = rd_f128(fp), gu2 = rd_f128(fp);
            long long half = len / 2;
            launch_sumcheck_fold(cf, ccb, nf, ncb, half, r);
            CK(cudaGetLastError());
            { F128* t; t = cf; cf = nf; nf = t; t = ccb; ccb = ncb; ncb = t; }
            len = half;
            dev_msg(cf, ccb, len, p0, p2, du0, du2, u0, u2);
            if (!eq(u0, gu0) || !eq(u2, gu2)) {
                printf("FOLD op %u FAIL (len->%lld)\n", op, len); return 1;
            }
        } else if (op_type == 1) {
            // introduce(b_new) + glue(beta): message over (f, b_new), then cb += beta*b_new.
            uint32_t cur = rd_u32(fp);
            if ((long long)cur != len) { printf("intro op %u: cur_len %u != len %lld\n", op, cur, len); return 1; }
            bnew_host.resize(cur);
            for (uint32_t i = 0; i < cur; i++) bnew_host[i] = rd_f128(fp);
            F128 beta = rd_f128(fp);
            F128 gu0 = rd_f128(fp), gu2 = rd_f128(fp);
            CK(cudaMemcpy(dbnew, bnew_host.data(), (size_t)cur * sizeof(F128), cudaMemcpyHostToDevice));
            dev_msg(cf, dbnew, len, p0, p2, du0, du2, u0, u2);
            if (!eq(u0, gu0) || !eq(u2, gu2)) { printf("INTRODUCE op %u FAIL\n", op); return 1; }
            launch_glue(ccb, dbnew, beta, len);
            CK(cudaGetLastError());
            CK(cudaDeviceSynchronize());
        } else {
            printf("bad op_type %u\n", op_type); return 1;
        }
    }

    F128 gfinal = rd_f128(fp);
    fclose(fp);
    F128 final_f;
    CK(cudaMemcpy(&final_f, cf, sizeof(F128), cudaMemcpyDeviceToHost));
    if (!eq(final_f, gfinal)) {
        printf("FINAL_F FAIL: got %016llx:%016llx exp %016llx:%016llx\n",
               (unsigned long long)final_f.hi, (unsigned long long)final_f.lo,
               (unsigned long long)gfinal.hi, (unsigned long long)gfinal.lo);
        return 1;
    }

    printf("SUMCHECK-PROVER OK: full transcript (%u ops) + final f match the real "
           "Ligerito SumcheckProver bit-for-bit\n", n_ops);
    cudaFree(df); cudaFree(dcb); cudaFree(df2); cudaFree(dcb2); cudaFree(dbnew);
    cudaFree(p0); cudaFree(p2); cudaFree(du0); cudaFree(du2);
    return 0;
}
