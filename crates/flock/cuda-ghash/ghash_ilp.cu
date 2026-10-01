#include <cstdio>
#include "f128.cuh"
#define CK(x) do{cudaError_t e=(x); if(e){printf("err %s\n",cudaGetErrorString(e));return 1;}}while(0)
static const u64 G=0x9E3779B97F4A7C15ull;
template<int K> __global__ void ghash_tp(int iters,F128*o){
  int t=blockIdx.x*blockDim.x+threadIdx.x;
  F128 a[K];
  #pragma unroll
  for(int k=0;k<K;k++) a[k]=F128{0xDEADBEEFull*(k+1)^t, 0x0123456789ABCDEFull+k};
  F128 b={0xFEDCBA98ull^t,0xA5A5A5A5A5A5A5A5ull};
  for(int i=0;i<iters;i++){
    #pragma unroll
    for(int k=0;k<K;k++) a[k]=ghash_mul_karatsuba(a[k],b);
    b.lo+=G;
  }
  F128 s={0,0};
  #pragma unroll
  for(int k=0;k<K;k++) s=f128_add(s,a[k]);
  o[t]=s;
}
template<int K> void run(int blk,int tpb,long thr,F128*o){
  long target=4'000'000'000L; int iters=(int)(target/(thr*K)); if(iters<1)iters=1;
  double ops=(double)thr*iters*K;
  ghash_tp<K><<<blk,tpb>>>(iters,o); cudaDeviceSynchronize();
  cudaEvent_t s,e; cudaEventCreate(&s);cudaEventCreate(&e); float best=1e30f;
  for(int r=0;r<3;r++){cudaEventRecord(s);ghash_tp<K><<<blk,tpb>>>(iters,o);cudaEventRecord(e);cudaEventSynchronize(e);float ms;cudaEventElapsedTime(&ms,s,e);if(ms<best)best=ms;}
  int regs; cudaFuncGetAttributes((cudaFuncAttributes*)nullptr,nullptr); // placeholder
  printf("  ILP=%-2d : %.2f GMul/s   (%.3f TCLMAD/s effective)\n", K, ops/(best*1e6), ops*6/(best*1e9));
}
int main(){
  cudaDeviceProp p; CK(cudaGetDeviceProperties(&p,0));
  int sm=p.multiProcessorCount,tpb=256,blk=sm*32; long thr=(long)blk*tpb;
  F128*o; CK(cudaMalloc(&o,thr*sizeof(F128)));
  printf("Device: %s | karatsuba GHASH, varying accumulators/thread\n",p.name);
  run<4>(blk,tpb,thr,o); run<6>(blk,tpb,thr,o); run<8>(blk,tpb,thr,o);
  run<12>(blk,tpb,thr,o); run<16>(blk,tpb,thr,o);
  return 0;
}
