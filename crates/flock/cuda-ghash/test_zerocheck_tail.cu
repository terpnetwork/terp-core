// Bit-for-bit validation of the CUDA zerocheck sumcheck tail against the flock
// oracle from src/bin/dump_zerocheck_tail_vectors.rs (ZTAL). Per round: build
// eq from r[1..], compute the eq-weighted message (g_one, g_inf), check vs
// golden, fold by ρ; check final a/b.
//
// Build:  make test_zerocheck_tail
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include "zerocheck_tail.cuh"
#include "ntt_host.hpp"

#define CK(x) do { cudaError_t e=(x); if(e){ printf("CUDA error %s @%d\n", cudaGetErrorString(e), __LINE__); exit(1);} } while(0)

static uint32_t rd_u32(FILE* f){ uint32_t v=0; if(fread(&v,4,1,f)!=1){printf("short u32\n");exit(1);} return v; }
static F128 rd_f128(FILE* f){ u64 v[2]; if(fread(v,8,2,f)!=2){printf("short f128\n");exit(1);} return F128{v[0],v[1]}; }
static bool eqf(F128 a, F128 b){ return a.lo==b.lo && a.hi==b.hi; }

// build_eq (LSB-first), matching univariate_skip.rs::build_eq.
static std::vector<F128> build_eq_host(const std::vector<F128>& r){
    const F128 ONE{1,0};
    std::vector<F128> t; t.reserve((size_t)1<<r.size()); t.push_back(ONE);
    for(size_t j=0;j<r.size();j++){ F128 rj=r[j], omr=f128_add_hd(ONE,rj); size_t len=(size_t)1<<j; t.resize(2*len);
        for(size_t x=0;x<len;x++){ F128 v=t[x]; t[x+len]=f128_mul_hd(v,rj); t[x]=f128_mul_hd(v,omr);} }
    return t;
}

int main(int argc, char** argv){
    const char* path = argc>1?argv[1]:"zerocheck_tail_vectors.bin";
    FILE* f = fopen(path,"rb");
    if(!f){ printf("cannot open %s\n", path); return 1; }
    if(rd_u32(f)!=0x5A54414Cu){ printf("bad magic (want ZTAL)\n"); return 1; }
    int L=(int)rd_u32(f);
    long long n = 1LL<<L;
    std::vector<F128> a(n), b(n);
    for(auto&v:a) v=rd_f128(f);
    for(auto&v:b) v=rd_f128(f);

    printf("ZTAL: L=%d n=%lld rounds=%d\n", L, n, L);

    F128 *dA,*dB,*dAn,*dBn,*dEq,*d_p1,*d_pinf,*d_m1,*d_minf;
    CK(cudaMalloc(&dA,n*sizeof(F128))); CK(cudaMalloc(&dB,n*sizeof(F128)));
    CK(cudaMalloc(&dAn,n*sizeof(F128))); CK(cudaMalloc(&dBn,n*sizeof(F128)));
    CK(cudaMalloc(&dEq,(n/2>1?n/2:1)*sizeof(F128)));
    CK(cudaMalloc(&d_p1,ZT_MAX_BLOCKS*sizeof(F128))); CK(cudaMalloc(&d_pinf,ZT_MAX_BLOCKS*sizeof(F128)));
    CK(cudaMalloc(&d_m1,sizeof(F128))); CK(cudaMalloc(&d_minf,sizeof(F128)));
    CK(cudaMemcpy(dA,a.data(),n*sizeof(F128),cudaMemcpyHostToDevice));
    CK(cudaMemcpy(dB,b.data(),n*sizeof(F128),cudaMemcpyHostToDevice));

    F128 *cA=dA,*cB=dB,*nA=dAn,*nB=dBn;
    long long len=n;
    for(int rnd=0; rnd<L; rnd++){
        int log_cur = __builtin_ctzll(len);
        long long half = len/2;
        // r_rest = r[1..] (log_cur-1 elements); eq = build_eq(r_rest), length half.
        std::vector<F128> r_rest(log_cur-1);
        for(auto&v:r_rest) v=rd_f128(f);
        std::vector<F128> eq = build_eq_host(r_rest);
        if((long long)eq.size()!=half){ printf("eq size %zu != %lld\n", eq.size(), half); return 1; }
        CK(cudaMemcpy(dEq, eq.data(), half*sizeof(F128), cudaMemcpyHostToDevice));

        launch_zerocheck_tail_message(cA, cB, dEq, half, d_p1, d_pinf, d_m1, d_minf);
        CK(cudaGetLastError());
        F128 m1, minf; CK(cudaMemcpy(&m1,d_m1,sizeof(F128),cudaMemcpyDeviceToHost));
        CK(cudaMemcpy(&minf,d_minf,sizeof(F128),cudaMemcpyDeviceToHost));
        F128 g_m1=rd_f128(f), g_minf=rd_f128(f), rho=rd_f128(f);
        if(!eqf(m1,g_m1)||!eqf(minf,g_minf)){
            printf("MSG FAIL round %d: m1 got %016llx:%016llx exp %016llx:%016llx | minf got %016llx:%016llx exp %016llx:%016llx\n",
                rnd,(unsigned long long)m1.hi,(unsigned long long)m1.lo,(unsigned long long)g_m1.hi,(unsigned long long)g_m1.lo,
                (unsigned long long)minf.hi,(unsigned long long)minf.lo,(unsigned long long)g_minf.hi,(unsigned long long)g_minf.lo);
            return 1;
        }
        launch_sumcheck_fold(cA, cB, nA, nB, half, rho);
        CK(cudaGetLastError()); CK(cudaDeviceSynchronize());
        F128* t; t=cA;cA=nA;nA=t; t=cB;cB=nB;nB=t;
        len=half;
        printf("  round %2d  len %8lld -> %8lld  msg+fold OK\n", rnd, len*2, len);
    }
    F128 fa, fb; CK(cudaMemcpy(&fa,cA,sizeof(F128),cudaMemcpyDeviceToHost));
    CK(cudaMemcpy(&fb,cB,sizeof(F128),cudaMemcpyDeviceToHost));
    F128 gfa=rd_f128(f), gfb=rd_f128(f);
    fclose(f);
    if(!eqf(fa,gfa)||!eqf(fb,gfb)){ printf("FINAL FAIL\n"); return 1; }
    printf("ZEROCHECK TAIL OK: %d rounds (eq-weighted message + fold) + final a,b match flock bit-for-bit\n", L);
    return 0;
}
