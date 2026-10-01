// Byte-exact validation of the CPU-structured GPU round-1 kernel against the ZCR1
// golden. Build: make test_zc_CPU-structured_gpu ; run on a zcr1 vector file.
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include "zerocheck_round1_cpustyle.cuh"
#include "phi8_table.cuh"
#include "ntt_host.hpp"

#define CK(x) do { cudaError_t e=(x); if(e){ printf("CUDA err %s @%d\n", cudaGetErrorString(e), __LINE__); exit(1);} } while(0)
static uint32_t rd_u32(FILE* f){ uint32_t v=0; if(fread(&v,4,1,f)!=1){exit(1);} return v; }
static F128 rd_f128(FILE* f){ u64 v[2]; if(fread(v,8,2,f)!=2){exit(1);} return F128{v[0],v[1]}; }
static bool eqf(F128 a, F128 b){ return a.lo==b.lo && a.hi==b.hi; }
static std::vector<F128> build_eq(const std::vector<F128>& r){
    const F128 ONE{1,0}; std::vector<F128> t; t.push_back(ONE);
    for(size_t j=0;j<r.size();j++){ F128 rj=r[j], omr=f128_add_hd(ONE,rj); size_t len=(size_t)1<<j; t.resize(2*len);
        for(size_t x=0;x<len;x++){ F128 v=t[x]; t[x+len]=f128_mul_hd(v,rj); t[x]=f128_mul_hd(v,omr);} }
    return t;
}

int main(int argc, char** argv){
    const char* path = argc>1?argv[1]:"zcr1_m16.bin";
    FILE* f=fopen(path,"rb"); if(!f){printf("cannot open %s\n",path);return 1;}
    if(rd_u32(f)!=0x5A435231u){printf("bad magic\n");return 1;}
    int m=(int)rd_u32(f), k_skip=(int)rd_u32(f); rd_u32(f); rd_u32(f);
    std::vector<F128> r(m); for(auto&v:r) v=rd_f128(f);
    std::vector<uint8_t> mcol(64*64), f8mul((size_t)256*256);
    fread(mcol.data(),1,mcol.size(),f); fread(f8mul.data(),1,f8mul.size(),f);
    size_t pb=(size_t)1<<(m-3);
    std::vector<uint8_t> A(pb),B(pb),C(pb);
    fread(A.data(),1,pb,f); fread(B.data(),1,pb,f); fread(C.data(),1,pb,f);
    std::vector<F128> g_ab(64), g_c(64); for(auto&v:g_ab)v=rd_f128(f); for(auto&v:g_c)v=rd_f128(f);
    fclose(f);
    printf("ZCR1: m=%d  n_out=%d\n", m, 1<<(m-13));

    std::vector<F128> r_small(r.begin()+k_skip, r.begin()+k_skip+3);
    std::vector<F128> r_med(r.begin()+k_skip+3, r.begin()+k_skip+7);
    std::vector<F128> r_out(r.begin()+k_skip+7, r.end());
    std::vector<F128> eq_small=build_eq(r_small), eq_med=build_eq(r_med), eq_out=build_eq(r_out);
    long long n_out=(long long)eq_out.size();
    F128 scale=f128_mul_hd(eq_small[0], eq_med[0]);
    upload_zerocheck_first_round_tables(mcol.data(), f8mul.data(), PHI_8_TABLE);   // uploads g_zc_t0, g_zc_f8mul

    uint8_t *d_a,*d_b,*d_c; F128 *d_eq,*d_ab,*d_c_out;
    CK(cudaMalloc(&d_a,pb)); CK(cudaMalloc(&d_b,pb)); CK(cudaMalloc(&d_c,pb));
    CK(cudaMalloc(&d_eq,n_out*sizeof(F128)));
    CK(cudaMalloc(&d_ab,64*sizeof(F128))); CK(cudaMalloc(&d_c_out,64*sizeof(F128)));
    CK(cudaMemcpy(d_a,A.data(),pb,cudaMemcpyHostToDevice));
    CK(cudaMemcpy(d_b,B.data(),pb,cudaMemcpyHostToDevice));
    CK(cudaMemcpy(d_c,C.data(),pb,cudaMemcpyHostToDevice));
    CK(cudaMemcpy(d_eq,eq_out.data(),n_out*sizeof(F128),cudaMemcpyHostToDevice));
    launch_zerocheck_first_round_cpu_structured(d_a,d_b,d_c,d_eq,n_out,scale,d_ab,d_c_out);
    CK(cudaGetLastError()); CK(cudaDeviceSynchronize());

    std::vector<F128> ab(64),cc(64);
    CK(cudaMemcpy(ab.data(),d_ab,64*sizeof(F128),cudaMemcpyDeviceToHost));
    CK(cudaMemcpy(cc.data(),d_c_out,64*sizeof(F128),cudaMemcpyDeviceToHost));
    int bad=0; for(int i=0;i<64;i++){ if(!eqf(ab[i],g_ab[i]))bad++; if(!eqf(cc[i],g_c[i]))bad++; }
    printf("CPU-STYLE GPU round-1: %s (%d/128 bad)\n", bad?"FAIL":"OK (oracle)", bad);
    return bad?1:0;
}
