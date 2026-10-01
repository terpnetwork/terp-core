// Validate the device challenger (zc_challenger_device.cuh) bit-identical to the host
// FsChallenger (challenger.hpp): snapshot a host state, run N device rounds and N host
// rounds on the same messages, compare every sampled rho. Build: make test_zc_challenger
#include <cstdio>
#include <cstdint>
#include <vector>
#include "f128.cuh"
#include "challenger.hpp"
#include "zc_challenger_device.cuh"
#define CK(x) do{ cudaError_t e=(x); if(e){printf("CUDA %s @%d\n",cudaGetErrorString(e),__LINE__);return 1;} }while(0)

// Pack a host Sha256 into the device ZcSha layout (fields differ in width/padding).
static ZcSha pack(const Sha256& s) {
    ZcSha z; for (int i=0;i<8;i++) z.h[i]=s.h[i];
    z.total_len=s.total_len; for(int i=0;i<64;i++) z.buf[i]=s.buf[i]; z.buf_len=(unsigned)s.buf_len;
    return z;
}
int main() {
    // seed a host challenger with some history (like after round1/round2 observes).
    FsChallenger ch((const uint8_t*)"dom",3); ch.observe_label((const uint8_t*)"flock-zerocheck-v0", 18);
    for (int i = 0; i < 70; i++) ch.observe_f128(ChF128{(uint64_t)(i*1234567+1), (uint64_t)(i*7654321+3)});
    ch.sample_f128(); ch.sample_f128();

    ZcSha *d_st; F128 *d_m1,*d_mi,*d_rho,*d_rstore;
    CK(cudaMalloc(&d_st,sizeof(ZcSha))); CK(cudaMalloc(&d_m1,16)); CK(cudaMalloc(&d_mi,16));
    CK(cudaMalloc(&d_rho,16)); CK(cudaMalloc(&d_rstore,16));
    ZcSha z = pack(ch.hasher); CK(cudaMemcpy(d_st,&z,sizeof(ZcSha),cudaMemcpyHostToDevice));

    int bad = 0;
    for (int round = 0; round < 25; round++) {
        F128 m1{(uint64_t)(round*0x9E3779B1u+1), (uint64_t)(round*0xBF58476Du+5)};
        F128 mi{(uint64_t)(round*0x2545F491u+7), (uint64_t)(round*0x94D049BBu+9)};
        // device round
        CK(cudaMemcpy(d_m1,&m1,16,cudaMemcpyHostToDevice));
        CK(cudaMemcpy(d_mi,&mi,16,cudaMemcpyHostToDevice));
        advance_zerocheck_tail_challenger<<<1,1>>>(d_st,d_m1,d_mi,d_rho,d_rstore,nullptr,nullptr);
        F128 rho_dev; CK(cudaMemcpy(&rho_dev,d_rho,16,cudaMemcpyDeviceToHost));
        // host round
        ch.observe_f128(ChF128{m1.lo,m1.hi}); ch.observe_f128(ChF128{mi.lo,mi.hi});
        ChF128 rho_host = ch.sample_f128();
        if (rho_dev.lo!=rho_host.lo || rho_dev.hi!=rho_host.hi) {
            printf("round %d MISMATCH dev{%016llx,%016llx} host{%016llx,%016llx}\n",
                   round,(unsigned long long)rho_dev.lo,(unsigned long long)rho_dev.hi,
                   (unsigned long long)rho_host.lo,(unsigned long long)rho_host.hi); bad++;
        }
    }
    printf("DEVICE CHALLENGER %s (%d/25 rounds bit-identical)\n", bad?"FAIL":"OK", 25-bad);
    return bad?1:0;
}
