// Validate the GPU transpose-NTT induce (scatter + transpose-NTT + truncate)
// byte-for-bit against the real induce_sumcheck_poly_via_ntt
// (dump_transpose_induce_vectors.rs, TRNI). This is the GPU fast path for induce.
//
// Build:  make test_transpose_induce
// Run:    (repo) cargo run --release --bin dump_transpose_induce_vectors -- cuda-ghash/transpose_induce_vectors.bin 16 1 218
//         (cuda-ghash) ./test_transpose_induce transpose_induce_vectors.bin
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include "ntt_transpose.cuh"
#include "induce_sumcheck.cuh"   // build_eq_device

#define CK(x) do { cudaError_t e=(x); if(e){ printf("CUDA err %s @%d\n", cudaGetErrorString(e), __LINE__); exit(1);} } while(0)
static uint32_t rd_u32(FILE* f){ uint32_t v; if(fread(&v,4,1,f)!=1){printf("short\n");exit(1);} return v; }
static uint64_t rd_u64(FILE* f){ uint64_t v; if(fread(&v,8,1,f)!=1){printf("short\n");exit(1);} return v; }
static F128 rd_f128(FILE* f){ u64 v[2]; if(fread(v,8,2,f)!=2){printf("short\n");exit(1);} return F128{v[0],v[1]}; }
static bool eqf(F128 a, F128 b){ return a.lo==b.lo && a.hi==b.hi; }

int main(int argc, char** argv){
    const char* path = argc>1?argv[1]:"transpose_induce_vectors.bin";
    FILE* f = fopen(path,"rb");
    if(!f){ printf("cannot open %s\n", path); return 1; }
    if(rd_u32(f)!=0x54524E49u){ printf("bad file (want TRNI)\n"); return 1; }
    int log_msg_cols=(int)rd_u32(f), log_inv_rate=(int)rd_u32(f);
    int n_queries=(int)rd_u32(f), alpha_len=(int)rd_u32(f);
    int log_block = log_msg_cols + log_inv_rate;
    long long block_len = 1LL<<log_block, n = 1LL<<log_msg_cols;

    std::vector<unsigned long long> queries(n_queries);
    for(int i=0;i<n_queries;i++) queries[i]=rd_u64(f);
    std::vector<F128> alpha(alpha_len);
    for(int i=0;i<alpha_len;i++) alpha[i]=rd_f128(f);
    uint32_t gn = rd_u32(f);
    std::vector<F128> golden(gn);
    for(uint32_t i=0;i<gn;i++) golden[i]=rd_f128(f);
    fclose(f);
    printf("TRNI: log_msg_cols=%d log_inv_rate=%d n_queries=%d block_len=%lld n=%lld\n",
           log_msg_cols, log_inv_rate, n_queries, block_len, n);

    // alpha_pows = build_eq_table(alpha) on device (>= n_queries entries).
    long long ap_len = 1LL << alpha_len;
    F128 *d_ap, *d_c; unsigned long long* d_q;
    CK(cudaMalloc(&d_ap, ap_len*sizeof(F128)));
    build_eq_device(d_ap, alpha.data(), alpha_len);

    // scatter into a zeroed codeword-domain buffer, transpose-NTT, truncate.
    CK(cudaMalloc(&d_c, block_len*sizeof(F128)));
    CK(cudaMalloc(&d_q, n_queries*sizeof(unsigned long long)));
    CK(cudaMemcpy(d_q, queries.data(), n_queries*sizeof(unsigned long long), cudaMemcpyHostToDevice));
    int tpb=256;
    clear_field_elements<<<(unsigned)((block_len+tpb-1)/tpb),tpb>>>(d_c, block_len);
    scatter_query_weights<<<(unsigned)((n_queries+tpb-1)/tpb),tpb>>>(d_c, d_q, d_ap, n_queries);
    CK(cudaGetLastError());

    F128* d_tw; TwiddleTable tt = build_twiddle_table(log_block);
    CK(cudaMalloc(&d_tw, tt.data.size()*sizeof(F128)));
    CK(cudaMemcpy(d_tw, tt.data.data(), tt.data.size()*sizeof(F128), cudaMemcpyHostToDevice));
    launch_transpose_ntt(d_c, d_tw, tt, log_block);
    CK(cudaGetLastError()); CK(cudaDeviceSynchronize());

    std::vector<F128> got(n);
    CK(cudaMemcpy(got.data(), d_c, (size_t)n*sizeof(F128), cudaMemcpyDeviceToHost));  // first n = truncation
    size_t bad=0, first=0;
    for(long long i=0;i<n;i++) if(!eqf(got[i], golden[i])){ if(!bad)first=i; bad++; }
    if(bad){
        F128 g=got[first], e=golden[first];
        printf("TRANSPOSE-INDUCE FAIL: %zu/%lld mismatch; first @%zu got %016llx:%016llx exp %016llx:%016llx\n",
               bad, n, first, (unsigned long long)g.hi,(unsigned long long)g.lo,(unsigned long long)e.hi,(unsigned long long)e.lo);
        return 1;
    }
    printf("TRANSPOSE-INDUCE OK: GPU scatter+transpose-NTT basis (%lld elems) matches induce_sumcheck_poly_via_ntt byte-for-bit\n", n);

    // timing: scatter + transpose-NTT (the induce hot path)
    cudaEvent_t ea, eb; CK(cudaEventCreate(&ea)); CK(cudaEventCreate(&eb));
    int iters = 50;
    clear_field_elements<<<(unsigned)((block_len+tpb-1)/tpb),tpb>>>(d_c, block_len); CK(cudaDeviceSynchronize());
    CK(cudaEventRecord(ea));
    for (int it=0; it<iters; it++) {
        clear_field_elements<<<(unsigned)((block_len+tpb-1)/tpb),tpb>>>(d_c, block_len);
        scatter_query_weights<<<(unsigned)((n_queries+tpb-1)/tpb),tpb>>>(d_c, d_q, d_ap, n_queries);
        launch_transpose_ntt(d_c, d_tw, tt, log_block);
    }
    CK(cudaEventRecord(eb)); CK(cudaEventSynchronize(eb));
    float ms=0; CK(cudaEventElapsedTime(&ms, ea, eb));
    printf("  timing: %.4f ms/call (block_len=2^%d, %d layers, %d queries) — vs dense induce ~5.6 ms\n",
           ms/iters, log_block, log_block, n_queries);
    cudaFree(d_ap); cudaFree(d_c); cudaFree(d_q); cudaFree(d_tw);
    return 0;
}
