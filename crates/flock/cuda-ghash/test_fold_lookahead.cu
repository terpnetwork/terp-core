// The open's fold chunk: two-round lookahead vs one fold+message per pass.
//
// Same idea as test_zerocheck_lookahead, for the sumcheck_ab kernels that drive
// pcs::open's fold rounds. Compares the challenge sequence AND both folded
// arrays, over both parities of initial_k (an odd count leaves one challenge to
// a plain trailing fold).
//
// No Rust oracle needed: the one-round-per-pass chain is the reference, itself
// pinned to flock by test_sumcheck_prover and test_ligerito_l0.
//
// Build: make test_fold_lookahead      Run: ./test_fold_lookahead
#include <cstdio>
#include <cstdlib>
#include <vector>
#include "f128.cuh"
#include "ntt_host.hpp"
#include "sumcheck_ab.cuh"

#define CK(x) do { cudaError_t e=(x); if(e){ printf("CUDA err %s @%d\n", cudaGetErrorString(e), __LINE__); exit(1);} } while(0)

static F128 mix(F128 a, F128 b) {
    F128 k1{0xA5A5F00D12345678ull, 0x0F1E2D3C4B5A6978ull};
    F128 k2{0x1122334455667788ull, 0x99AABBCCDDEEFF01ull};
    return f128_add_hd(f128_mul_hd(a, k1), f128_mul_hd(b, k2));
}
static F128 interp3(F128 h0, F128 h1, F128 hinf, F128 rho) {
    F128 c1 = f128_add_hd(f128_add_hd(h0, h1), hinf);
    return f128_add_hd(h0, f128_mul_hd(rho, f128_add_hd(c1, f128_mul_hd(rho, hinf))));
}
__global__ void fill_f128(F128* p, long long n, unsigned seed) {
    long long i = blockIdx.x * (long long)blockDim.x + threadIdx.x;
    if (i >= n) return;
    unsigned long long s = (unsigned long long)i * 0x9E3779B97F4A7C15ull + seed;
    s ^= s >> 29; s *= 0xBF58476D1CE4E5B9ull;
    p[i] = F128{s, s * 0x94D049BB133111EBull + seed};
}

int main() {
    int fails = 0;
    for (int nlog : {16, 20, 24}) for (int initial_k : {6, 5, 4, 3}) {
        long long len = 1LL << nlog;
        F128 *a0, *b0, *A, *B, *An, *Bn, *p0, *p2, *du0, *part, *out8;
        CK(cudaMalloc(&a0, len*sizeof(F128))); CK(cudaMalloc(&b0, len*sizeof(F128)));
        CK(cudaMalloc(&A, len*sizeof(F128)));  CK(cudaMalloc(&B, len*sizeof(F128)));
        CK(cudaMalloc(&An, len*sizeof(F128))); CK(cudaMalloc(&Bn, len*sizeof(F128)));
        CK(cudaMalloc(&p0, SMC_MAX_BLOCKS*sizeof(F128)));
        CK(cudaMalloc(&p2, SMC_MAX_BLOCKS*sizeof(F128)));
        CK(cudaMalloc(&du0, 2*sizeof(F128)));
        CK(cudaMalloc(&part, 8*SMC_MAX_BLOCKS*sizeof(F128)));
        CK(cudaMalloc(&out8, 8*sizeof(F128)));
        fill_f128<<<(unsigned)((len+255)/256),256>>>(a0, len, 5);
        fill_f128<<<(unsigned)((len+255)/256),256>>>(b0, len, 9);

        std::vector<F128> refr, gotr;
        std::vector<F128> reffA, gotfA, reffB, gotfB;
        long long ref_slen = 0, got_slen = 0;

        // ---------- reference ----------
        {
            F128 *cf=A,*ccb=B,*nf=An,*ncb=Bn; long long slen=len;
            CK(cudaMemcpy(cf,a0,len*sizeof(F128),cudaMemcpyDeviceToDevice));
            CK(cudaMemcpy(ccb,b0,len*sizeof(F128),cudaMemcpyDeviceToDevice));
            F128 u0,u2;
            launch_sumcheck_message(cf,ccb,slen/2,p0,p2,du0,du0+1);
            CK(cudaDeviceSynchronize());
            { F128 u[2]; CK(cudaMemcpy(u,du0,2*sizeof(F128),cudaMemcpyDeviceToHost)); u0=u[0]; u2=u[1]; }
            F128 last = mix(u0,u2);
            for (int k=0;k<initial_k;k++) {
                refr.push_back(last);
                long long half=slen/2;
                launch_sumcheck_fold_and_message(cf,ccb,nf,ncb,half,refr.back(),p0,p2,du0,du0+1);
                {F128*z;z=cf;cf=nf;nf=z;z=ccb;ccb=ncb;ncb=z;} slen=half;
                CK(cudaDeviceSynchronize());
                { F128 u[2]; CK(cudaMemcpy(u,du0,2*sizeof(F128),cudaMemcpyDeviceToHost)); u0=u[0]; u2=u[1]; }
                last = mix(u0,u2);
            }
            ref_slen = slen;
            reffA.resize(slen); reffB.resize(slen);
            CK(cudaMemcpy(reffA.data(),cf,slen*sizeof(F128),cudaMemcpyDeviceToHost));
            CK(cudaMemcpy(reffB.data(),ccb,slen*sizeof(F128),cudaMemcpyDeviceToHost));
        }

        // ---------- lookahead ----------
        {
            F128 *cf=A,*ccb=B,*nf=An,*ncb=Bn; long long slen=len;
            CK(cudaMemcpy(cf,a0,len*sizeof(F128),cudaMemcpyDeviceToDevice));
            CK(cudaMemcpy(ccb,b0,len*sizeof(F128),cudaMemcpyDeviceToDevice));
            int blocks = sumcheck_blocks(slen/4);
            sumcheck_lookahead_message_partial<<<blocks,SMC_TPB>>>(cf,ccb,slen/4,part);
            combine_sumcheck_lookahead_message<<<8,SMC_TPB>>>(part,blocks,out8);
            CK(cudaDeviceSynchronize());
            int j = 0;
            auto obs = [&](F128 a, F128 b) {
                if (j < initial_k) gotr.push_back(mix(a,b));
                j++;
            };
            F128 h[8]; CK(cudaMemcpy(h,out8,8*sizeof(F128),cudaMemcpyDeviceToHost));
            obs(h[0],h[1]);
            if (j <= initial_k) { F128 rr = gotr.back();
                obs(interp3(h[2],h[3],h[4],rr), interp3(h[5],h[6],h[7],rr)); }
            int folds = 0;
            while (folds + 2 <= initial_k) {
                launch_sumcheck_lookahead(cf,ccb,nf,ncb,slen/16,gotr[folds],gotr[folds+1],part,out8);
                {F128*z;z=cf;cf=nf;nf=z;z=ccb;ccb=ncb;ncb=z;} slen/=4; folds+=2;
                CK(cudaDeviceSynchronize());
                CK(cudaMemcpy(h,out8,8*sizeof(F128),cudaMemcpyDeviceToHost));
                obs(h[0],h[1]);
                if (j <= initial_k) { F128 rr = gotr.back();
                    obs(interp3(h[2],h[3],h[4],rr), interp3(h[5],h[6],h[7],rr)); }
            }
            for (; folds < initial_k; folds++) {
                long long half=slen/2;
                launch_sumcheck_fold(cf,ccb,nf,ncb,half,gotr[folds]);
                {F128*z;z=cf;cf=nf;nf=z;z=ccb;ccb=ncb;ncb=z;} slen=half;
            }
            got_slen = slen;
            gotfA.resize(slen); gotfB.resize(slen);
            CK(cudaDeviceSynchronize());
            CK(cudaMemcpy(gotfA.data(),cf,slen*sizeof(F128),cudaMemcpyDeviceToHost));
            CK(cudaMemcpy(gotfB.data(),ccb,slen*sizeof(F128),cudaMemcpyDeviceToHost));
        }

        int bad = 0;
        if ((int)refr.size()!=initial_k || refr.size()!=gotr.size()) {
            printf("  challenge count %zu vs %zu (want %d)\n", refr.size(), gotr.size(), initial_k); bad=1; }
        else for (size_t q=0;q<refr.size();q++)
            if (refr[q].lo!=gotr[q].lo||refr[q].hi!=gotr[q].hi) { printf("  rho[%zu] differs\n",q); bad=1; break; }
        if (ref_slen != got_slen) { printf("  slen %lld vs %lld\n", ref_slen, got_slen); bad=1; }
        else for (long long q=0;q<ref_slen && !bad;q++) {
            if (reffA[q].lo!=gotfA[q].lo||reffA[q].hi!=gotfA[q].hi) { printf("  folded f[%lld] differs\n",q); bad=1; }
            if (reffB[q].lo!=gotfB[q].lo||reffB[q].hi!=gotfB[q].hi) { printf("  folded b[%lld] differs\n",q); bad=1; }
        }
        fails += bad;
        printf("  %s len=2^%-2d initial_k=%d  %d challenges + folded f,b (2^%d) match\n",
               bad?"BAD":"ok ", nlog, initial_k, (int)refr.size(),
               (int)(63-__builtin_clzll((unsigned long long)ref_slen)));

        cudaFree(a0);cudaFree(b0);cudaFree(A);cudaFree(B);cudaFree(An);cudaFree(Bn);
        cudaFree(p0);cudaFree(p2);cudaFree(du0);cudaFree(part);cudaFree(out8);
    }
    printf(fails ? "\nFAILED (%d)\n" : "\nopen fold chunk: lookahead transcript identical\n", fails);
    return fails ? 1 : 0;
}
