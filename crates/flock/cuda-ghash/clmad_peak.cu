#include <cstdio>
#include "f128.cuh"
#define CK(x) do{cudaError_t e=(x); if(e){printf("err %s\n",cudaGetErrorString(e));return 1;}}while(0)
static const u64 G=0x9E3779B97F4A7C15ull;
// 8 independent dependent-chains of pure clmad.lo -> measures raw CLMAD issue rate
__global__ void peak(int iters,u64*o){
  int t=blockIdx.x*blockDim.x+threadIdx.x;
  u64 a0=t+1,a1=t+2,a2=t+3,a3=t+4,a4=t+5,a5=t+6,a6=t+7,a7=t+8;
  u64 b=0x1234u^t, c=0x9abcu^t;
  for(int i=0;i<iters;i++){
    a0=clmad_lo(a0,b,c); a1=clmad_lo(a1,b,c); a2=clmad_lo(a2,b,c); a3=clmad_lo(a3,b,c);
    a4=clmad_lo(a4,b,c); a5=clmad_lo(a5,b,c); a6=clmad_lo(a6,b,c); a7=clmad_lo(a7,b,c);
    b+=G;
  }
  o[t]=a0^a1^a2^a3^a4^a5^a6^a7;
}
int main(){
  cudaDeviceProp p; CK(cudaGetDeviceProperties(&p,0));
  int sm=p.multiProcessorCount, tpb=256, blk=sm*32; long thr=(long)blk*tpb;
  u64*o; CK(cudaMalloc(&o,thr*8));
  int iters=4000; double clmads=(double)thr*iters*8;
  peak<<<blk,tpb>>>(iters,o); CK(cudaDeviceSynchronize());
  cudaEvent_t s,e; cudaEventCreate(&s);cudaEventCreate(&e);
  float best=1e30f;
  for(int r=0;r<3;r++){cudaEventRecord(s);peak<<<blk,tpb>>>(iters,o);cudaEventRecord(e);cudaEventSynchronize(e);float ms;cudaEventElapsedTime(&ms,s,e);if(ms<best)best=ms;}
  printf("Device: %s | %d SMs\n",p.name,sm);
  printf("Raw CLMAD peak: %.2f TCLMAD/s  (%.1f GCLMAD/s)  [%.0f MCLMAD in %.2f ms]\n",
         clmads/(best*1e9), clmads/(best*1e6), clmads/1e6, best);
  printf("=> implied GHASH-mul ceiling (6 CLMAD/mul): %.1f GMul/s\n", clmads/(best*1e6)/6.0);
  return 0;
}
