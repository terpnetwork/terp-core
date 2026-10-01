// Bit-for-bit validation of the CUDA zerocheck round-2 (fold-at-z + first mlv
// message) against the flock oracle from dump_zerocheck_round2_vectors.rs (ZR2).
//
// Build:  make test_zerocheck_round2
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include "zerocheck_round2.cuh"
#include "zerocheck_tail.cuh"   // launch_zerocheck_tail_message (eq-weighted message)
#include "ntt_host.hpp"

#define CK(x) do { cudaError_t e=(x); if(e){ printf("CUDA error %s @%d\n", cudaGetErrorString(e), __LINE__); exit(1);} } while(0)

static uint32_t rd_u32(FILE* f){ uint32_t v=0; if(fread(&v,4,1,f)!=1){printf("short u32\n");exit(1);} return v; }
static F128 rd_f128(FILE* f){ u64 v[2]; if(fread(v,8,2,f)!=2){printf("short f128\n");exit(1);} return F128{v[0],v[1]}; }
static bool eqf(F128 a, F128 b){ return a.lo==b.lo && a.hi==b.hi; }

static std::vector<F128> build_eq_host(const std::vector<F128>& r){
    const F128 ONE{1,0};
    std::vector<F128> t; t.reserve((size_t)1<<r.size()); t.push_back(ONE);
    for(size_t j=0;j<r.size();j++){ F128 rj=r[j], omr=f128_add_hd(ONE,rj); size_t len=(size_t)1<<j; t.resize(2*len);
        for(size_t x=0;x<len;x++){ F128 v=t[x]; t[x+len]=f128_mul_hd(v,rj); t[x]=f128_mul_hd(v,omr);} }
    return t;
}

int main(int argc, char** argv){
    const char* path = argc>1?argv[1]:"zerocheck_round2_vectors.bin";
    FILE* f = fopen(path,"rb");
    if(!f){ printf("cannot open %s\n", path); return 1; }
    if(rd_u32(f)!=0x5A523202u){ printf("bad magic (want ZR2)\n"); return 1; }
    int m=(int)rd_u32(f);
    int k_skip=6;
    long long n_out = 1LL << (m - k_skip);
    size_t pb = (size_t)1 << (m - 3);

    F128 z = rd_f128(f); (void)z;
    std::vector<F128> mlv(m - k_skip); for(auto&v:mlv) v=rd_f128(f);
    std::vector<F128> foldtable(8*256); for(auto&v:foldtable) v=rd_f128(f);
    std::vector<uint8_t> a(pb), b(pb);
    if(fread(a.data(),1,pb,f)!=pb||fread(b.data(),1,pb,f)!=pb){printf("short ab\n");return 1;}
    std::vector<F128> g_amlv(n_out), g_bmlv(n_out);
    for(auto&v:g_amlv) v=rd_f128(f);
    for(auto&v:g_bmlv) v=rd_f128(f);
    F128 g_m1=rd_f128(f), g_minf=rd_f128(f);
    fclose(f);

    printf("ZR2: m=%d n_out=%lld\n", m, n_out);

    uint8_t *d_a,*d_b; F128 *d_ft,*d_am,*d_bm,*d_eq,*d_p1,*d_pinf,*d_m1,*d_minf;
    CK(cudaMalloc(&d_a,pb)); CK(cudaMalloc(&d_b,pb));
    CK(cudaMalloc(&d_ft,foldtable.size()*sizeof(F128)));
    CK(cudaMalloc(&d_am,n_out*sizeof(F128))); CK(cudaMalloc(&d_bm,n_out*sizeof(F128)));
    CK(cudaMalloc(&d_eq,(n_out/2>1?n_out/2:1)*sizeof(F128)));
    CK(cudaMalloc(&d_p1,ZT_MAX_BLOCKS*sizeof(F128))); CK(cudaMalloc(&d_pinf,ZT_MAX_BLOCKS*sizeof(F128)));
    CK(cudaMalloc(&d_m1,sizeof(F128))); CK(cudaMalloc(&d_minf,sizeof(F128)));
    CK(cudaMemcpy(d_a,a.data(),pb,cudaMemcpyHostToDevice));
    CK(cudaMemcpy(d_b,b.data(),pb,cudaMemcpyHostToDevice));
    CK(cudaMemcpy(d_ft,foldtable.data(),foldtable.size()*sizeof(F128),cudaMemcpyHostToDevice));

    // ---- fold-at-z ----
    launch_zerocheck_second_round_fold(d_a, d_b, d_ft, n_out, d_am, d_bm);
    CK(cudaGetLastError()); CK(cudaDeviceSynchronize());
    std::vector<F128> amlv(n_out), bmlv(n_out);
    CK(cudaMemcpy(amlv.data(),d_am,n_out*sizeof(F128),cudaMemcpyDeviceToHost));
    CK(cudaMemcpy(bmlv.data(),d_bm,n_out*sizeof(F128),cudaMemcpyDeviceToHost));
    for(long long i=0;i<n_out;i++){
        if(!eqf(amlv[i],g_amlv[i])){ printf("A_MLV FAIL [%lld]\n",i); return 1; }
        if(!eqf(bmlv[i],g_bmlv[i])){ printf("B_MLV FAIL [%lld]\n",i); return 1; }
    }
    printf("  fold-at-z OK (a_mlv,b_mlv, %lld rows)\n", n_out);

    // ---- first message: eq = build_eq(mlv[1..]) ----
    std::vector<F128> mlv_rest(mlv.begin()+1, mlv.end());
    std::vector<F128> eq = build_eq_host(mlv_rest);
    long long half = n_out/2;
    if((long long)eq.size()!=half){ printf("eq size %zu != %lld\n", eq.size(), half); return 1; }
    CK(cudaMemcpy(d_eq,eq.data(),half*sizeof(F128),cudaMemcpyHostToDevice));
    launch_zerocheck_tail_message(d_am, d_bm, d_eq, half, d_p1, d_pinf, d_m1, d_minf);
    CK(cudaGetLastError());
    F128 m1, minf; CK(cudaMemcpy(&m1,d_m1,sizeof(F128),cudaMemcpyDeviceToHost));
    CK(cudaMemcpy(&minf,d_minf,sizeof(F128),cudaMemcpyDeviceToHost));
    if(!eqf(m1,g_m1)||!eqf(minf,g_minf)){
        printf("MSG FAIL: m1 got %016llx:%016llx exp %016llx:%016llx | minf got %016llx:%016llx exp %016llx:%016llx\n",
            (unsigned long long)m1.hi,(unsigned long long)m1.lo,(unsigned long long)g_m1.hi,(unsigned long long)g_m1.lo,
            (unsigned long long)minf.hi,(unsigned long long)minf.lo,(unsigned long long)g_minf.hi,(unsigned long long)g_minf.lo);
        return 1;
    }
    printf("  first message OK (msg_1, msg_inf)\n");
    printf("ZEROCHECK ROUND-2 OK: fold-at-z + first message match flock bit-for-bit\n");
    return 0;
}
