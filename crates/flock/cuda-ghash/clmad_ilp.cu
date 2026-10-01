#include <cstdio>
#include "f128.cuh"
#define CK(x) do{cudaError_t e=(x); if(e){printf("err %s\n",cudaGetErrorString(e));return 1;}}while(0)
static const u64 G=0x9E3779B97F4A7C15ull;
template<int K> __global__ void peak(int iters,u64*o){
  int t=blockIdx.x*blockDim.x+threadIdx.x;
  u64 a[K];
  #pragma unroll
  for(int k=0;k<K;k++) a[k]=t+1+k;
  u64 b=0x1234u^t, c=0x9abcu^t;
  for(int i=0;i<iters;i++){
    #pragma unroll
    for(int k=0;k<K;k++) a[k]=clmad_lo(a[k],b,c);
    b+=G;
  }
  u64 s=0;
  #pragma unroll
  for(int k=0;k<K;k++) s^=a[k];
  o[t]=s;
}
template<int K> void run(int blk,int tpb,long thr,u64*o){
  long target=24'000'000'000L; int iters=(int)(target/(thr*K)); if(iters<1)iters=1;
  double cl=(double)thr*iters*K;
  peak<K><<<blk,tpb>>>(iters,o); cudaDeviceSynchronize();
  cudaEvent_t s,e; cudaEventCreate(&s);cudaEventCreate(&e); float best=1e30f;
  for(int r=0;r<3;r++){cudaEventRecord(s);peak<K><<<blk,tpb>>>(iters,o);cudaEventRecord(e);cudaEventSynchronize(e);float ms;cudaEventElapsedTime(&ms,s,e);if(ms<best)best=ms;}
  printf("  ILP=%-2d (independent clmad chains/thread): %.2f TCLMAD/s\n", K, cl/(best*1e9));
}
int main(){
  cudaDeviceProp p; CK(cudaGetDeviceProperties(&p,0));
  int sm=p.multiProcessorCount,tpb=256,blk=sm*32; long thr=(long)blk*tpb;
  u64*o; CK(cudaMalloc(&o,thr*8));
  printf("Device: %s | %d SMs | %ld threads (so even ILP=1 has huge TLP)\n",p.name,sm,thr);
  run<1>(blk,tpb,thr,o); run<2>(blk,tpb,thr,o); run<4>(blk,tpb,thr,o);
  run<8>(blk,tpb,thr,o); run<16>(blk,tpb,thr,o); run<32>(blk,tpb,thr,o);
  return 0;
}
