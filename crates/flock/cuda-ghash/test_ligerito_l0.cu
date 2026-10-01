// Full Ligerito L0-phase orchestrator — step 6 (final assembly) of the GPU
// pcs::open / Ligerito port. Reproduces an entire L0 phase of
// recursive_prover_with_basis_impl on device + host challenger, validated
// byte-for-byte against the real prover (dump_ligerito_l0_vectors.rs):
//   L0 commit → observe → initial_k folds → commit f¹ → OOD intro/glue →
//   query grind+sample+α → open rows + multi-proof → induce basis₀ → introduce/glue.
//
// Host FsChallenger DERIVES every challenge; device kernels (NTT, Merkle,
// sumcheck fold/msg, msg_eval, glue, induce) do the compute. Each phase's
// output binds the next challenge, so a full pass proves the orchestration is
// byte-identical to the real prover.
//
// Build:  make test_ligerito_l0
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>
#include "ntt_f128.cuh"
#include "merkle.cuh"
#include "merkle_open.hpp"
#include "induce_sumcheck.cuh"
#include "introduce_glue.cuh"
#include "sumcheck_ab.cuh"
#include "challenger.hpp"

#define CK(x) do { cudaError_t e=(x); if(e){ \
    printf("CUDA error %s at %s:%d\n", cudaGetErrorString(e), __FILE__, __LINE__); \
    exit(1);} } while(0)

static const uint8_t PROVER_LABEL[] = "flock-ligerito-basis-v0";

__global__ void replicate_fill(const F128* __restrict__ msg, F128* __restrict__ cw,
                               long long cw_len, long long msg_len) {
    long long i = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= cw_len) return;
    cw[i] = msg[i % msg_len];
}

static uint32_t rd_u32(FILE* f) { uint32_t v; if (fread(&v, 4, 1, f) != 1) { printf("short u32\n"); exit(1); } return v; }
static uint64_t rd_u64(FILE* f) { uint64_t v; if (fread(&v, 8, 1, f) != 1) { printf("short u64\n"); exit(1); } return v; }
static F128 rd_f128(FILE* f) { u64 v[2]; if (fread(v, 8, 2, f) != 2) { printf("short f128\n"); exit(1); } return F128{v[0], v[1]}; }
static bool eqf(F128 a, F128 b) { return a.lo == b.lo && a.hi == b.hi; }
static ChF128 to_ch(F128 x) { return ChF128{x.lo, x.hi}; }
// Build a ligero_commit on device: replicate-fill `src` (len 2^msg_log) → NTT →
// Merkle. Returns root (host) and leaves the codeword in d_cw, tree in d_tree.
static void ligero_commit_dev(const F128* d_src, int msg_log, int log_msg_cols, int log_ni,
                              int log_inv_rate, F128*& d_cw, uint8_t*& d_tree,
                              long long& block_len, int& num_ntts, uint8_t out_root[32]) {
    int k_code = log_msg_cols + log_inv_rate;
    num_ntts = 1 << log_ni;
    block_len = 1LL << k_code;
    long long cw_len = block_len * num_ntts;
    long long msg_len = 1LL << msg_log;
    F128* d_tw;
    TwiddleTable tt = build_twiddle_table(k_code);
    CK(cudaMalloc(&d_cw, cw_len * sizeof(F128)));
    CK(cudaMalloc(&d_tw, tt.data.size() * sizeof(F128)));
    CK(cudaMemcpy(d_tw, tt.data.data(), tt.data.size() * sizeof(F128), cudaMemcpyHostToDevice));
    CK(cudaMalloc(&d_tree, (size_t)(2 * block_len - 1) * 32));
    // Rate-extend fusion (same as bench_ligerito::commit_dev): first shared-memory pass
    // reads the message directly instead of a replicate_fill'd codeword.
    if (ntt_can_fuse_source(k_code - log_inv_rate)) {
        launch_ntt(d_cw, d_tw, tt, log_inv_rate, k_code, num_ntts, 256, d_src, msg_len - 1);
    } else {
        int tpb = 256;
        replicate_fill<<<(unsigned)((cw_len + tpb - 1) / tpb), tpb>>>(d_src, d_cw, cw_len, msg_len);
        launch_ntt(d_cw, d_tw, tt, log_inv_rate, k_code, num_ntts);
    }
    CK(cudaGetLastError());
    launch_merkle((const uint8_t*)d_cw, d_tree, block_len, num_ntts * 16);
    CK(cudaDeviceSynchronize());
    CK(cudaMemcpy(out_root, d_tree + (size_t)(2 * block_len - 2) * 32, 32, cudaMemcpyDeviceToHost));
    cudaFree(d_tw);
}

static void dev_msg(const F128* A, const F128* B, long long len, F128* p0, F128* p2,
                    F128* du0, F128* du2, F128& u0, F128& u2) {
    launch_sumcheck_message(A, B, len / 2, p0, p2, du0, du2);
    CK(cudaGetLastError());
    CK(cudaMemcpy(&u0, du0, sizeof(F128), cudaMemcpyDeviceToHost));
    CK(cudaMemcpy(&u2, du2, sizeof(F128), cudaMemcpyDeviceToHost));
}

int main(int argc, char** argv) {
    const char* path = argc > 1 ? argv[1] : "ligerito_l0_vectors.bin";
    FILE* fp = fopen(path, "rb");
    if (!fp) { printf("cannot open %s\n", path); return 1; }

    if (rd_u32(fp) != 0x4C305343u) { printf("bad file (want L0SC)\n"); return 1; }
    uint32_t dlen = rd_u32(fp);
    std::vector<uint8_t> domain(dlen);
    if (dlen && fread(domain.data(), 1, dlen, fp) != dlen) { printf("short domain\n"); return 1; }
    int log_n = (int)rd_u32(fp);
    uint32_t len = rd_u32(fp);
    std::vector<F128> f(len), b1(len);
    for (uint32_t i = 0; i < len; i++) f[i] = rd_f128(fp);
    for (uint32_t i = 0; i < len; i++) b1[i] = rd_f128(fp);
    F128 target = rd_f128(fp);
    int log_inv_rate_0 = (int)rd_u32(fp);
    uint8_t g_l0root[32];
    if (fread(g_l0root, 1, 32, fp) != 32) { printf("short l0root\n"); return 1; }
    int initial_k = (int)rd_u32(fp);
    uint32_t fold_bits = rd_u32(fp);
    F128 g_s0 = rd_f128(fp), g_s2 = rd_f128(fp);

    int n1 = log_n - initial_k;
    long long n1_len = 1LL << n1;
    int num_interleaved_0 = 1 << initial_k;
    printf("L0SC: log_n=%d initial_k=%d n1=%d fold_bits=%u rate0=1/%d\n",
           log_n, initial_k, n1, fold_bits, 1 << log_inv_rate_0);

    // ---- upload witness; build L0 commit on device ----
    F128 *d_f, *d_b1;
    CK(cudaMalloc(&d_f, (size_t)len * sizeof(F128)));
    CK(cudaMalloc(&d_b1, (size_t)len * sizeof(F128)));
    CK(cudaMemcpy(d_f, f.data(), (size_t)len * sizeof(F128), cudaMemcpyHostToDevice));
    CK(cudaMemcpy(d_b1, b1.data(), (size_t)len * sizeof(F128), cudaMemcpyHostToDevice));

    F128 *d_cw0; uint8_t *d_tree0; long long l0_block_len; int l0_lanes;
    uint8_t l0root[32];
    ligero_commit_dev(d_f, log_n, log_n - initial_k, initial_k, log_inv_rate_0,
                      d_cw0, d_tree0, l0_block_len, l0_lanes, l0root);
    if (memcmp(l0root, g_l0root, 32) != 0) { printf("L0 COMMIT ROOT FAIL\n"); return 1; }

    // host copies for opening: L0 codeword + tree.
    std::vector<F128> h_cw0((size_t)l0_block_len * l0_lanes);
    CK(cudaMemcpy(h_cw0.data(), d_cw0, h_cw0.size() * sizeof(F128), cudaMemcpyDeviceToHost));
    std::vector<MHash> h_tree0(2 * l0_block_len - 1);
    CK(cudaMemcpy(h_tree0.data(), d_tree0, h_tree0.size() * 32, cudaMemcpyDeviceToHost));

    // ---- challenger: observe label, target, L0 root ----
    FsChallenger ch(domain.data(), dlen);
    ch.observe_label(PROVER_LABEL, sizeof(PROVER_LABEL) - 1);
    ch.observe_f128(to_ch(target));
    ch.observe_bytes(l0root, 32);

    // ---- resident sumcheck state ----
    F128 *df, *dcb, *df2, *dcb2, *du0, *du2, *p0, *p2;
    CK(cudaMalloc(&df, (size_t)len * sizeof(F128)));   CK(cudaMalloc(&dcb, (size_t)len * sizeof(F128)));
    CK(cudaMalloc(&df2, (size_t)len * sizeof(F128)));  CK(cudaMalloc(&dcb2, (size_t)len * sizeof(F128)));
    CK(cudaMalloc(&p0, SMC_MAX_BLOCKS * sizeof(F128))); CK(cudaMalloc(&p2, SMC_MAX_BLOCKS * sizeof(F128)));
    CK(cudaMalloc(&du0, sizeof(F128)));                 CK(cudaMalloc(&du2, sizeof(F128)));
    CK(cudaMemcpy(df, f.data(), (size_t)len * sizeof(F128), cudaMemcpyHostToDevice));
    CK(cudaMemcpy(dcb, b1.data(), (size_t)len * sizeof(F128), cudaMemcpyHostToDevice));
    F128 *cf = df, *ccb = dcb, *nf = df2, *ncb = dcb2;
    long long slen = len;

    F128 u0, u2;
    dev_msg(cf, ccb, slen, p0, p2, du0, du2, u0, u2);
    if (!eqf(u0, g_s0) || !eqf(u2, g_s2)) { printf("START_MSG FAIL\n"); return 1; }
    ch.observe_f128(to_ch(u0)); ch.observe_f128(to_ch(u2));

    std::vector<F128> r_lane_fold;
    for (int k = 0; k < initial_k; k++) {
        if (fold_bits > 0) {
            uint64_t en = rd_u64(fp), gn = ch.grind_pow(fold_bits);
            if (gn != en) { printf("FOLD GRIND %d FAIL\n", k); return 1; }
        }
        ChF128 rc = ch.sample_f128(); F128 r{rc.lo, rc.hi};
        F128 gr = rd_f128(fp), gu0 = rd_f128(fp), gu2 = rd_f128(fp);
        if (!eqf(r, gr)) { printf("FOLD CHAL %d FAIL\n", k); return 1; }
        long long half = slen / 2;
        launch_sumcheck_fold_and_message(cf, ccb, nf, ncb, half, r, p0, p2, du0, du2); CK(cudaGetLastError());  // fused fold + next msg
        { F128* t; t = cf; cf = nf; nf = t; t = ccb; ccb = ncb; ncb = t; }
        slen = half;
        CK(cudaMemcpy(&u0,du0,sizeof(F128),cudaMemcpyDeviceToHost));CK(cudaMemcpy(&u2,du2,sizeof(F128),cudaMemcpyDeviceToHost));
        if (!eqf(u0, gu0) || !eqf(u2, gu2)) { printf("FOLD MSG %d FAIL\n", k); return 1; }
        ch.observe_f128(to_ch(u0)); ch.observe_f128(to_ch(u2));
        r_lane_fold.push_back(r);
    }
    { F128 gh = rd_f128(fp), h; CK(cudaMemcpy(&h, cf, sizeof(F128), cudaMemcpyDeviceToHost));
      if (!eqf(h, gh)) { printf("FOLDED HEAD FAIL\n"); return 1; } }

    // ---- commit f¹ ----
    int log_ni1 = (int)rd_u32(fp), log_inv_rate_1 = (int)rd_u32(fp);
    uint8_t g_root1[32]; if (fread(g_root1, 1, 32, fp) != 32) { printf("short root1\n"); return 1; }
    F128 *d_cw1; uint8_t *d_tree1; long long bl1; int lanes1; uint8_t root1[32];
    ligero_commit_dev(cf, n1, n1 - log_ni1, log_ni1, log_inv_rate_1, d_cw1, d_tree1, bl1, lanes1, root1);
    if (memcmp(root1, g_root1, 32) != 0) { printf("COMMIT f1 ROOT FAIL\n"); return 1; }
    ch.observe_bytes(root1, 32);
    // Keep wtns_1 for the recursive last level's query opening.
    std::vector<F128> h_cw1((size_t)bl1 * lanes1);
    CK(cudaMemcpy(h_cw1.data(), d_cw1, h_cw1.size() * sizeof(F128), cudaMemcpyDeviceToHost));
    std::vector<MHash> h_tree1(2 * bl1 - 1);
    CK(cudaMemcpy(h_tree1.data(), d_tree1, h_tree1.size() * 32, cudaMemcpyDeviceToHost));
    cudaFree(d_cw1); cudaFree(d_tree1);

    // ---- OOD intro/glue ----
    F128 *d_bnew, *ep0, *ep2, *epodd, *eu0, *eu2, *ehnew;
    CK(cudaMalloc(&d_bnew, n1_len * sizeof(F128)));
    CK(cudaMalloc(&ep0, IGL_MAX_BLOCKS * sizeof(F128))); CK(cudaMalloc(&ep2, IGL_MAX_BLOCKS * sizeof(F128)));
    CK(cudaMalloc(&epodd, IGL_MAX_BLOCKS * sizeof(F128)));
    CK(cudaMalloc(&eu0, sizeof(F128))); CK(cudaMalloc(&eu2, sizeof(F128))); CK(cudaMalloc(&ehnew, sizeof(F128)));
    uint32_t ood_count = rd_u32(fp);
    for (uint32_t o = 0; o < ood_count; o++) {
        std::vector<ChF128> z(n1); ch.sample_f128_vec(z.data(), n1);
        std::vector<F128> zf(n1);
        for (int i = 0; i < n1; i++) { F128 gz = rd_f128(fp); if (!eqf(F128{z[i].lo,z[i].hi}, gz)) { printf("OOD z FAIL\n"); return 1; } zf[i] = F128{z[i].lo, z[i].hi}; }
        build_eq_device(d_bnew, zf.data(), n1);   // device eq (perf path)
        launch_basis_message_evaluation(cf, d_bnew, n1_len / 2, ep0, ep2, epodd, eu0, eu2, ehnew); CK(cudaGetLastError());
        F128 iu0, iu2, y;
        CK(cudaMemcpy(&iu0, eu0, sizeof(F128), cudaMemcpyDeviceToHost));
        CK(cudaMemcpy(&iu2, eu2, sizeof(F128), cudaMemcpyDeviceToHost));
        CK(cudaMemcpy(&y, ehnew, sizeof(F128), cudaMemcpyDeviceToHost));
        F128 gy = rd_f128(fp), giu0 = rd_f128(fp), giu2 = rd_f128(fp), gbeta = rd_f128(fp);
        if (!eqf(y, gy) || !eqf(iu0, giu0) || !eqf(iu2, giu2)) { printf("OOD msg FAIL\n"); return 1; }
        ch.observe_f128(to_ch(y)); ch.observe_f128(to_ch(iu0)); ch.observe_f128(to_ch(iu2));
        ChF128 bc = ch.sample_f128();
        if (!eqf(F128{bc.lo, bc.hi}, gbeta)) { printf("OOD beta FAIL\n"); return 1; }
        launch_glue(ccb, d_bnew, F128{bc.lo, bc.hi}, n1_len); CK(cudaGetLastError()); CK(cudaDeviceSynchronize());
    }

    // ---- query grind + sample queries + α ----
    uint32_t query_grind_bits = rd_u32(fp), num_queries_0 = rd_u32(fp);
    uint64_t g_nonce0 = rd_u64(fp), g_l0bl = rd_u64(fp);
    uint64_t got_nonce0 = ch.grind_pow(query_grind_bits);
    if (got_nonce0 != g_nonce0) { printf("QUERY GRIND FAIL\n"); return 1; }
    if ((long long)g_l0bl != l0_block_len) { printf("l0_block_len mismatch %llu vs %lld\n", (unsigned long long)g_l0bl, l0_block_len); return 1; }
    std::vector<size_t> queries = ch.sample_distinct_queries((size_t)l0_block_len, num_queries_0);
    for (uint32_t i = 0; i < num_queries_0; i++) { uint64_t gq = rd_u64(fp); if (queries[i] != (size_t)gq) { printf("QUERY %u FAIL\n", i); return 1; } }
    uint32_t alpha_len = rd_u32(fp);
    std::vector<ChF128> alpha(alpha_len); ch.sample_f128_vec(alpha.data(), alpha_len);
    std::vector<F128> alpha_f(alpha_len);
    for (uint32_t i = 0; i < alpha_len; i++) { F128 ga = rd_f128(fp); if (!eqf(F128{alpha[i].lo,alpha[i].hi}, ga)) { printf("ALPHA %u FAIL\n", i); return 1; } alpha_f[i] = F128{alpha[i].lo, alpha[i].hi}; }

    // ---- open rows + multi-proof ----
    std::vector<F128> opened_rows((size_t)num_queries_0 * num_interleaved_0);
    for (uint32_t i = 0; i < num_queries_0; i++)
        memcpy(&opened_rows[(size_t)i * num_interleaved_0], &h_cw0[queries[i] * num_interleaved_0], num_interleaved_0 * sizeof(F128));
    std::vector<MHash> proof = merkle_multi_proof_host(h_tree0.data(), (size_t)l0_block_len, queries);
    uint32_t g_prooflen = rd_u32(fp);
    if (proof.size() != g_prooflen) { printf("MULTI-PROOF LEN FAIL: %zu vs %u\n", proof.size(), g_prooflen); return 1; }
    for (uint32_t i = 0; i < g_prooflen; i++) { MHash g; if (fread(g.b, 1, 32, fp) != 32) { printf("short proof\n"); return 1; } if (!mhash_eq(proof[i], g)) { printf("MULTI-PROOF %u FAIL\n", i); return 1; } }

    // ---- induce basis₀ ----
    std::vector<unsigned long long> q_ull(num_queries_0);
    for (uint32_t i = 0; i < num_queries_0; i++) q_ull[i] = queries[i];
    std::vector<F128> sks = eval_sk_at_vks_hd(n1);
    InduceSetupDev S = induce_setup_device(n1, sks, r_lane_fold, alpha_f, q_ull, opened_rows, num_interleaved_0);
    F128 *d_low = S.d_low, *d_sh = S.d_sh, *d_basis;
    CK(cudaMalloc(&d_basis, (size_t)n1_len * sizeof(F128)));
    launch_induce_accumulate(d_sh, d_low, S.n_queries, S.low_n, S.high_n, d_basis, n1_len);
    CK(cudaGetLastError()); CK(cudaDeviceSynchronize());
    std::vector<F128> basis(n1_len);
    CK(cudaMemcpy(basis.data(), d_basis, (size_t)n1_len * sizeof(F128), cudaMemcpyDeviceToHost));
    for (long long i = 0; i < n1_len; i++) { F128 gb = rd_f128(fp); if (!eqf(basis[i], gb)) { printf("BASIS_0 @%lld FAIL\n", i); return 1; } }
    F128 g_esum = rd_f128(fp);
    if (!eqf(S.enforced_sum, g_esum)) { printf("ENFORCED_SUM FAIL\n"); return 1; }

    // ---- introduce + glue basis₀ ----
    dev_msg(cf, d_basis, n1_len, p0, p2, du0, du2, u0, u2);  // round_msg over (f, basis_0)
    F128 g_iu0 = rd_f128(fp), g_iu2 = rd_f128(fp), g_beta0 = rd_f128(fp), g_head2 = rd_f128(fp);
    if (!eqf(u0, g_iu0) || !eqf(u2, g_iu2)) { printf("INTRO_MSG_0 FAIL\n"); return 1; }
    ch.observe_f128(to_ch(u0)); ch.observe_f128(to_ch(u2));
    ChF128 b0 = ch.sample_f128();
    if (!eqf(F128{b0.lo, b0.hi}, g_beta0)) { printf("BETA_0 FAIL\n"); return 1; }
    launch_glue(ccb, d_basis, F128{b0.lo, b0.hi}, n1_len); CK(cudaGetLastError()); CK(cudaDeviceSynchronize());
    { F128 h; CK(cudaMemcpy(&h, cf, sizeof(F128), cudaMemcpyDeviceToHost)); if (!eqf(h, g_head2)) { printf("POST-INTRO HEAD FAIL\n"); return 1; } }
    cudaFree(d_low); cudaFree(d_sh); cudaFree(d_basis);

    // ==== Recursive levels (general r): query wtns_prev, commit wtns_next ====
    int r = (int)rd_u32(fp);
    int k_rec = (int)rd_u32(fp);
    int rate_rec = (int)rd_u32(fp);
    int ood_rec = (int)rd_u32(fp);
    uint32_t foldgrind_rec = rd_u32(fp);
    uint32_t grind_rec = rd_u32(fp);

    std::vector<F128> prev_cw = h_cw1;       // wtns_1 codeword (host)
    std::vector<MHash> prev_tree = h_tree1;  // wtns_1 tree (host)
    long long prev_bl = bl1;
    int prev_ni = lanes1;

    for (int lvl = 0; lvl < r; lvl++) {
        std::vector<F128> level_rs;
        for (int k = 0; k < k_rec; k++) {
            if (foldgrind_rec > 0) { uint64_t en = rd_u64(fp), gn = ch.grind_pow(foldgrind_rec); if (gn != en) { printf("REC L%d FOLD GRIND %d FAIL\n", lvl, k); return 1; } }
            ChF128 rc = ch.sample_f128(); F128 rr{rc.lo, rc.hi};
            F128 gr = rd_f128(fp), gu0 = rd_f128(fp), gu2 = rd_f128(fp);
            if (!eqf(rr, gr)) { printf("REC L%d FOLD CHAL %d FAIL\n", lvl, k); return 1; }
            long long half = slen / 2;
            launch_sumcheck_fold_and_message(cf, ccb, nf, ncb, half, rr, p0, p2, du0, du2); CK(cudaGetLastError());  // fused fold + next msg
            { F128* t; t = cf; cf = nf; nf = t; t = ccb; ccb = ncb; ncb = t; }
            slen = half;
            CK(cudaMemcpy(&u0,du0,sizeof(F128),cudaMemcpyDeviceToHost));CK(cudaMemcpy(&u2,du2,sizeof(F128),cudaMemcpyDeviceToHost));
            if (!eqf(u0, gu0) || !eqf(u2, gu2)) { printf("REC L%d FOLD MSG %d FAIL\n", lvl, k); return 1; }
            ch.observe_f128(to_ch(u0)); ch.observe_f128(to_ch(u2));
            level_rs.push_back(rr);
        }

        if (lvl == r - 1) {
            // ---- last level: yr + grind + query wtns_prev ----
            uint32_t yr_len = rd_u32(fp);
            if ((long long)yr_len != slen) { printf("YR LEN %u vs %lld\n", yr_len, slen); return 1; }
            std::vector<F128> yr(yr_len);
            CK(cudaMemcpy(yr.data(), cf, (size_t)yr_len * sizeof(F128), cudaMemcpyDeviceToHost));
            for (uint32_t i = 0; i < yr_len; i++) { F128 gv = rd_f128(fp); if (!eqf(yr[i], gv)) { printf("YR[%u] FAIL\n", i); return 1; } ch.observe_f128(to_ch(yr[i])); }
            uint64_t g_nl = rd_u64(fp), g_pbl = rd_u64(fp);
            if (ch.grind_pow(grind_rec) != g_nl) { printf("LAST GRIND FAIL\n"); return 1; }
            if ((long long)g_pbl != prev_bl) { printf("prev_bl %llu vs %lld\n", (unsigned long long)g_pbl, prev_bl); return 1; }
            uint32_t nq = rd_u32(fp);
            std::vector<size_t> ql = ch.sample_distinct_queries((size_t)prev_bl, nq);
            for (uint32_t i = 0; i < nq; i++) { uint64_t gq = rd_u64(fp); if (ql[i] != (size_t)gq) { printf("LAST QUERY %u FAIL\n", i); return 1; } }
            std::vector<MHash> mp = merkle_multi_proof_host(prev_tree.data(), (size_t)prev_bl, ql);
            uint32_t gpl = rd_u32(fp);
            if (mp.size() != gpl) { printf("LAST PROOF LEN %zu vs %u\n", mp.size(), gpl); return 1; }
            for (uint32_t i = 0; i < gpl; i++) { MHash g; if (fread(g.b, 1, 32, fp) != 32) return 1; if (!mhash_eq(mp[i], g)) { printf("LAST PROOF %u FAIL\n", i); return 1; } }
        } else {
            // ---- non-last: commit f_next, OOD, query wtns_prev, induce, introduce/glue ----
            int n_next = 0; { long long s = slen; while (s > 1) { s >>= 1; n_next++; } }
            long long nn_len = 1LL << n_next;
            F128 *d_cwn; uint8_t *d_treen; long long bln; int lanesn; uint8_t rn[32];
            ligero_commit_dev(cf, n_next, n_next - k_rec, k_rec, rate_rec, d_cwn, d_treen, bln, lanesn, rn);
            uint8_t g_rn[32]; if (fread(g_rn, 1, 32, fp) != 32) return 1;
            if (memcmp(rn, g_rn, 32) != 0) { printf("REC L%d COMMIT ROOT FAIL\n", lvl); return 1; }
            ch.observe_bytes(rn, 32);
            std::vector<F128> next_cw((size_t)bln * lanesn);
            CK(cudaMemcpy(next_cw.data(), d_cwn, next_cw.size() * sizeof(F128), cudaMemcpyDeviceToHost));
            std::vector<MHash> next_tree(2 * bln - 1);
            CK(cudaMemcpy(next_tree.data(), d_treen, next_tree.size() * 32, cudaMemcpyDeviceToHost));
            cudaFree(d_cwn); cudaFree(d_treen);

            for (int o = 0; o < ood_rec; o++) {
                std::vector<ChF128> z(n_next); ch.sample_f128_vec(z.data(), n_next);
                std::vector<F128> zf(n_next);
                for (int j = 0; j < n_next; j++) { F128 gz = rd_f128(fp); if (!eqf(F128{z[j].lo,z[j].hi}, gz)) { printf("REC L%d OOD z FAIL\n", lvl); return 1; } zf[j] = F128{z[j].lo, z[j].hi}; }
                build_eq_device(d_bnew, zf.data(), n_next);   // device eq (perf path)
                launch_basis_message_evaluation(cf, d_bnew, nn_len / 2, ep0, ep2, epodd, eu0, eu2, ehnew); CK(cudaGetLastError());
                F128 iu0, iu2, y;
                CK(cudaMemcpy(&iu0, eu0, sizeof(F128), cudaMemcpyDeviceToHost));
                CK(cudaMemcpy(&iu2, eu2, sizeof(F128), cudaMemcpyDeviceToHost));
                CK(cudaMemcpy(&y, ehnew, sizeof(F128), cudaMemcpyDeviceToHost));
                F128 gy = rd_f128(fp), giu0 = rd_f128(fp), giu2 = rd_f128(fp), gbeta = rd_f128(fp);
                if (!eqf(y, gy) || !eqf(iu0, giu0) || !eqf(iu2, giu2)) { printf("REC L%d OOD msg FAIL\n", lvl); return 1; }
                ch.observe_f128(to_ch(y)); ch.observe_f128(to_ch(iu0)); ch.observe_f128(to_ch(iu2));
                ChF128 bc = ch.sample_f128();
                if (!eqf(F128{bc.lo,bc.hi}, gbeta)) { printf("REC L%d OOD beta FAIL\n", lvl); return 1; }
                launch_glue(ccb, d_bnew, F128{bc.lo, bc.hi}, nn_len); CK(cudaGetLastError()); CK(cudaDeviceSynchronize());
            }

            uint64_t g_ni = rd_u64(fp), g_pbl = rd_u64(fp);
            if (ch.grind_pow(grind_rec) != g_ni) { printf("REC L%d GRIND FAIL\n", lvl); return 1; }
            if ((long long)g_pbl != prev_bl) { printf("REC L%d prev_bl mismatch\n", lvl); return 1; }
            uint32_t nq = rd_u32(fp);
            std::vector<size_t> qi = ch.sample_distinct_queries((size_t)prev_bl, nq);
            for (uint32_t i = 0; i < nq; i++) { uint64_t gq = rd_u64(fp); if (qi[i] != (size_t)gq) { printf("REC L%d QUERY %u FAIL\n", lvl, i); return 1; } }
            uint32_t al = rd_u32(fp);
            std::vector<ChF128> alpha(al); ch.sample_f128_vec(alpha.data(), al);
            std::vector<F128> alpha_f(al);
            for (uint32_t i = 0; i < al; i++) { F128 ga = rd_f128(fp); if (!eqf(F128{alpha[i].lo,alpha[i].hi}, ga)) { printf("REC L%d ALPHA %u FAIL\n", lvl, i); return 1; } alpha_f[i] = F128{alpha[i].lo, alpha[i].hi}; }
            std::vector<MHash> mp = merkle_multi_proof_host(prev_tree.data(), (size_t)prev_bl, qi);
            uint32_t gpl = rd_u32(fp);
            if (mp.size() != gpl) { printf("REC L%d PROOF LEN %zu vs %u\n", lvl, mp.size(), gpl); return 1; }
            for (uint32_t i = 0; i < gpl; i++) { MHash g; if (fread(g.b, 1, 32, fp) != 32) return 1; if (!mhash_eq(mp[i], g)) { printf("REC L%d PROOF %u FAIL\n", lvl, i); return 1; } }

            std::vector<F128> opened((size_t)nq * prev_ni);
            for (uint32_t i = 0; i < nq; i++) memcpy(&opened[(size_t)i * prev_ni], &prev_cw[qi[i] * prev_ni], prev_ni * sizeof(F128));
            std::vector<unsigned long long> qull(nq); for (uint32_t i = 0; i < nq; i++) qull[i] = qi[i];
            std::vector<F128> sks = eval_sk_at_vks_hd(n_next);
            InduceSetupDev S = induce_setup_device(n_next, sks, level_rs, alpha_f, qull, opened, prev_ni);
            F128 *dl = S.d_low, *dsh = S.d_sh, *dbasis;
            CK(cudaMalloc(&dbasis, (size_t)nn_len * sizeof(F128)));
            launch_induce_accumulate(dsh, dl, S.n_queries, S.low_n, S.high_n, dbasis, nn_len);
            CK(cudaGetLastError()); CK(cudaDeviceSynchronize());
            std::vector<F128> basis(nn_len);
            CK(cudaMemcpy(basis.data(), dbasis, (size_t)nn_len * sizeof(F128), cudaMemcpyDeviceToHost));
            uint32_t gbl = rd_u32(fp);
            for (uint32_t i = 0; i < gbl; i++) { F128 gb = rd_f128(fp); if (!eqf(basis[i], gb)) { printf("REC L%d BASIS @%u FAIL\n", lvl, i); return 1; } }
            F128 g_es = rd_f128(fp);
            if (!eqf(S.enforced_sum, g_es)) { printf("REC L%d ESUM FAIL\n", lvl); return 1; }

            dev_msg(cf, dbasis, nn_len, p0, p2, du0, du2, u0, u2);
            F128 giu0 = rd_f128(fp), giu2 = rd_f128(fp), gbi = rd_f128(fp);
            if (!eqf(u0, giu0) || !eqf(u2, giu2)) { printf("REC L%d INTRO MSG FAIL\n", lvl); return 1; }
            ch.observe_f128(to_ch(u0)); ch.observe_f128(to_ch(u2));
            ChF128 bi = ch.sample_f128();
            if (!eqf(F128{bi.lo,bi.hi}, gbi)) { printf("REC L%d BETA FAIL\n", lvl); return 1; }
            launch_glue(ccb, dbasis, F128{bi.lo, bi.hi}, nn_len); CK(cudaGetLastError()); CK(cudaDeviceSynchronize());
            cudaFree(dl); cudaFree(dsh); cudaFree(dbasis);

            prev_cw = std::move(next_cw); prev_tree = std::move(next_tree); prev_bl = bln; prev_ni = lanesn;
        }
    }

    fclose(fp);
    printf("LIGERITO E2E (r=%d) OK: full L0 + %d recursive level(s) — entire prove transcript "
           "(commits, folds, OOD, induce, query/open, grinding) matches the real prover byte-for-bit\n",
           r, r);
    return 0;
}
