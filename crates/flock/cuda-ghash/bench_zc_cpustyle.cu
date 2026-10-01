// Throughput of the CPU-structured round-1 kernel. No oracle (correctness in
// test_zc_CPU-structured_gpu). Compare to removed warp path (~3.66 ms @ m=29) and CPU (~5 ms).
// Build: make bench_zc_CPU-structured ; run: ./bench_zc_CPU-structured [m] [iters]
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include "zerocheck_round1_cpustyle.cuh"
#include "phi8_table.cuh"
#define CK(x) do { cudaError_t e=(x); if(e){ printf("CUDA err %s @%d\n", cudaGetErrorString(e), __LINE__); exit(1);} } while(0)

__global__ void fill_bytes(uint8_t* z, size_t n){ size_t i=blockIdx.x*(size_t)blockDim.x+threadIdx.x; if(i>=n)return;
    u64 x=(u64)i*0x9E3779B97F4A7C15ull+1; z[i]=(uint8_t)(x^(x>>13)^(x>>29)); }
__global__ void fill_f128(F128* a, long long n){ long long i=blockIdx.x*(long long)blockDim.x+threadIdx.x; if(i>=n)return;
    u64 x=(u64)i*0x9E3779B97F4A7C15ull+1; a[i]=F128{x, x*0xBF58476D1CE4E5B9ull}; }

static void run_one(int m, int iters){
    long long n_out = 1LL << (m - 13);
    size_t packed = (size_t)1 << (m - 3);
    std::vector<uint8_t> mcol(64*64), f8mul((size_t)256*256);
    for(size_t i=0;i<mcol.size();i++) mcol[i]=(uint8_t)(i*7+1);
    for(size_t i=0;i<f8mul.size();i++) f8mul[i]=(uint8_t)(i^(i>>8));
    upload_zerocheck_first_round_tables(mcol.data(), f8mul.data(), PHI_8_TABLE);

    uint8_t *d_a,*d_b,*d_c; F128 *d_eq,*d_ab,*d_c_out;
    CK(cudaMalloc(&d_a,packed)); CK(cudaMalloc(&d_b,packed)); CK(cudaMalloc(&d_c,packed));
    CK(cudaMalloc(&d_eq,n_out*sizeof(F128)));
    CK(cudaMalloc(&d_ab,64*sizeof(F128))); CK(cudaMalloc(&d_c_out,64*sizeof(F128)));
    fill_bytes<<<(unsigned)((packed+255)/256),256>>>(d_a,packed);
    fill_bytes<<<(unsigned)((packed+255)/256),256>>>(d_b,packed);
    fill_bytes<<<(unsigned)((packed+255)/256),256>>>(d_c,packed);
    fill_f128<<<(unsigned)((n_out+255)/256),256>>>(d_eq,n_out);
    CK(cudaDeviceSynchronize());
    F128 scale{0x123,0x456};

    cudaEvent_t e0,e1; cudaEventCreate(&e0); cudaEventCreate(&e1);
    launch_zerocheck_first_round_cpu_structured(d_a,d_b,d_c,d_eq,n_out,scale,d_ab,d_c_out); CK(cudaDeviceSynchronize());
    float t=0;
    for(int it=0;it<iters;it++){
        cudaEventRecord(e0);
        launch_zerocheck_first_round_cpu_structured(d_a,d_b,d_c,d_eq,n_out,scale,d_ab,d_c_out);
        cudaEventRecord(e1); cudaEventSynchronize(e1);
        float ms=0; cudaEventElapsedTime(&ms,e0,e1); t+=ms;
    }
    t/=iters;
    printf("m=%2d n_out=%8lld rows=%10lld | CPU-structured %8.3f ms\n", m, n_out, n_out*128, t);
    cudaFree(d_a);cudaFree(d_b);cudaFree(d_c);cudaFree(d_eq);cudaFree(d_ab);cudaFree(d_c_out);
}
int main(int argc, char** argv){
    if(argc>=2){ run_one(atoi(argv[1]), argc>2?atoi(argv[2]):30); return 0; }
    printf("zerocheck round-1 CPU-structured throughput (RTX 5090)\n");
    for(int m=24;m<=29;m++) run_one(m,15);
    return 0;
}
