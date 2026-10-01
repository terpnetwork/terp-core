// Benchmark for the CUDA GF(2^128) GHASH port. Mirrors flare-avx
// benches/field.rs methodology:
//   * latency    — single-thread dependent chain  a = mul(a, b)
//   * throughput — 4 independent accumulators per thread (ILP) x full grid (TLP)
//   * checksum written to global memory so nothing is dead-code-eliminated
// plus a realistic GHASH/GCM workload: many parallel Horner authentication
// chains  acc = (acc ^ block) * H.
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <type_traits>
#include "f128.cuh"

#define CK(x) do { cudaError_t e=(x); if(e){ \
    printf("CUDA error %s at %s:%d\n", cudaGetErrorString(e), __FILE__, __LINE__); \
    exit(1);} } while(0)

// 0=software shift-XOR, 1=schoolbook+clmad, 2=binius+clmad, 3=karatsuba+clmad
template<int V> __device__ __forceinline__ F128 mulv(F128 a, F128 b);
template<> __device__ __forceinline__ F128 mulv<0>(F128 a, F128 b){ return ghash_mul_sw(a,b); }
template<> __device__ __forceinline__ F128 mulv<1>(F128 a, F128 b){ return ghash_mul_schoolbook(a,b); }
template<> __device__ __forceinline__ F128 mulv<2>(F128 a, F128 b){ return ghash_mul_binius(a,b); }
template<> __device__ __forceinline__ F128 mulv<3>(F128 a, F128 b){ return ghash_mul_karatsuba(a,b); }

static const u64 GOLD = 0x9E3779B97F4A7C15ull;
static const char* vname[4] = {"software shift-XOR", "schoolbook + clmad", "binius + clmad", "karatsuba + clmad"};

// K independent accumulators per thread (ILP) x full grid (TLP). K is a
// Template parameter for the ILP=4/8/16 sweep.
template<int V, int K>
__global__ void measure_multiplication_throughput(int iters, F128* out) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    F128 a[K];
    #pragma unroll
    for (int k = 0; k < K; k++)
        a[k] = {0xDEADBEEFCAFEBABEull ^ (u64)(tid + k * 0x1111),
                0x0123456789ABCDEFull + (u64)(k * 0x2222)};
    F128 b = {0xFEDCBA9876543210ull ^ (u64)tid, 0xA5A5A5A5A5A5A5A5ull};
    for (int i = 0; i < iters; i++) {
        #pragma unroll
        for (int k = 0; k < K; k++) a[k] = mulv<V>(a[k], b);
        b.lo += GOLD;                 // vary b: can't be hoisted/folded
    }
    F128 s = a[0];
    #pragma unroll
    for (int k = 1; k < K; k++) s = f128_add(s, a[k]);
    out[tid] = s;
}

template<int V>
__global__ void measure_multiplication_latency(F128 a0, F128 b0, int iters, F128* out) {
    F128 a = a0, b = b0;
    for (int i = 0; i < iters; i++) { a = mulv<V>(a, b); b.lo += GOLD; }
    out[0] = a;
}

// Realistic GCM: each thread authenticates an independent message of
// `nblocks` 16-byte blocks via Horner:  acc = (acc ^ block) * H.
template<int V>
__global__ void measure_ghash_throughput(F128 H, int nblocks, F128* out) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    F128 acc = {0, 0};
    F128 m = {0x100000001b3ull * (u64)(tid + 1), GOLD * (u64)(tid + 1)};
    for (int i = 0; i < nblocks; i++) {
        acc = f128_add(acc, m);
        acc = mulv<V>(acc, H);
        m.lo += 0x100000001b3ull; m.hi ^= m.lo;   // synthesize next block
    }
    out[tid] = acc;
}

struct Timer {
    cudaEvent_t s, e;
    Timer(){ cudaEventCreate(&s); cudaEventCreate(&e); }
    ~Timer(){ cudaEventDestroy(s); cudaEventDestroy(e); }
    void start(){ cudaEventRecord(s); }
    float stop_ms(){ cudaEventRecord(e); cudaEventSynchronize(e); float ms; cudaEventElapsedTime(&ms,s,e); return ms; }
};

// Run `fn` once to warm up, then 3 timed reps; return best (min) ms.
template<class F>
static float best_ms(F fn) {
    fn(); CK(cudaDeviceSynchronize());
    Timer t; float best = 1e30f;
    for (int r = 0; r < 3; r++) {
        t.start(); fn(); float ms = t.stop_ms();
        CK(cudaGetLastError());
        if (ms < best) best = ms;
    }
    return best;
}

int main() {
    int dev = 0; cudaDeviceProp p; CK(cudaGetDeviceProperties(&p, dev));
    int sm = p.multiProcessorCount;
    printf("Device: %s | %d SMs | sm_%d%d\n\n", p.name, sm, p.major, p.minor);

    const int tpb = 256;
    const int blocks = sm * 32;             // heavy oversubscription for TLP
    const long threads = (long)blocks * tpb;

    F128 *out; CK(cudaMalloc(&out, threads * sizeof(F128)));

    // ---- Throughput: device-aggregate GMul/s, ILP sweep ----
    printf("== Throughput (ILP sweep x %ld threads, device-aggregate GMul/s) ==\n", threads);
    {
        auto run = [&](auto V_ic, auto K_ic){
            constexpr int V = decltype(V_ic)::value, K = decltype(K_ic)::value;
            const long target = 4'000'000'000L;        // ~4G muls per measurement
            int iters = (int)(target / (threads * K));
            if (iters < 1) iters = 1;
            double ops = (double)threads * iters * K;
            float ms = best_ms([&]{ measure_multiplication_throughput<V,K><<<blocks,tpb>>>(iters,out); });
            printf("  %-20s ILP=%-2d %8.2f GMul/s   %7.3f ns/op(aggregate)\n",
                   vname[V], K, ops/(ms*1e6), ms*1e6/ops);
        };
        auto sweep = [&](auto V_ic){
            run(V_ic, std::integral_constant<int,4>{});
            run(V_ic, std::integral_constant<int,8>{});
            run(V_ic, std::integral_constant<int,16>{});
        };
        sweep(std::integral_constant<int,0>{});
        sweep(std::integral_constant<int,1>{});
        sweep(std::integral_constant<int,2>{});
        sweep(std::integral_constant<int,3>{});
    }

    // ---- Latency: single-thread dependent chain (comparable to CPU ns/op) ----
    printf("\n== Latency (single thread, dependent chain) ==\n");
    {
        const int iters = 2'000'000;
        F128 a0 = {0xDEADBEEFCAFEBABEull, 0x0123456789ABCDEFull};
        F128 b0 = {0xFEDCBA9876543210ull, 0xA5A5A5A5A5A5A5A5ull};
        auto run = [&](int V){
            float ms = (V==0)? best_ms([&]{ measure_multiplication_latency<0><<<1,1>>>(a0,b0,iters,out); })
                     : (V==1)? best_ms([&]{ measure_multiplication_latency<1><<<1,1>>>(a0,b0,iters,out); })
                     : (V==2)? best_ms([&]{ measure_multiplication_latency<2><<<1,1>>>(a0,b0,iters,out); })
                     :         best_ms([&]{ measure_multiplication_latency<3><<<1,1>>>(a0,b0,iters,out); });
            printf("  %-20s %8.2f ns/op   [%d iters in %.1f ms]\n",
                   vname[V], ms*1e6/iters, iters, ms);
        };
        run(3); run(2); run(1); run(0);
    }

    // ---- Realistic GHASH/GCM: parallel Horner authentication chains ----
    printf("\n== GHASH/GCM (parallel Horner chains, binius+clmad) ==\n");
    {
        const int nblocks = 1024;                       // 16 KiB message per chain
        double ops   = (double)threads * nblocks;       // muls
        double bytes = ops * 16.0;                       // 16 B per GHASH block
        F128 H = {0x0388dace60b6a392ull, 0x66e94bd4ef8a2c3bull};  // arbitrary hash key
        float ms = best_ms([&]{ measure_ghash_throughput<2><<<blocks,tpb>>>(H, nblocks, out); });
        printf("  %ld chains x %d blocks: %8.2f GMul/s   %7.1f GB/s   [%.1f ms]\n",
               threads, nblocks, ops/(ms*1e6), bytes/(ms*1e6), ms);
    }

    // Touch output so the compiler keeps everything.
    F128 h; CK(cudaMemcpy(&h, out, sizeof(F128), cudaMemcpyDeviceToHost));
    printf("\nchecksum[0] = %016llx:%016llx\n", h.hi, h.lo);

    printf("\nCPU reference (run `cargo bench --bench field` for this host's AVX numbers):\n");
    printf("  binary_fun C++ M-series binius mul latency ~5.7 ns/op single-core\n");
    return 0;
}
