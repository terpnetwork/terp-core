// Transposed forward additive-NTT — the GPU fast path for induce_sumcheck_poly
// (the user's insight: the transpose that parallelizes poorly on a 32-thread CPU
// is ideal on a GPU). Port of src/pcs/ligerito.rs::transpose_forward_ntt:
// the induced basis = G^T·c, where c is the sparse query-weight vector scattered
// over the codeword domain and G is the forward additive NTT. O(n·log n) +
// bandwidth-bound vs the dense O(n·n_queries).
//
// Transposed butterfly (vs forward `new_u = top + v·tw; bot = v + new_u`):
//   a' = a + b;   b' = t·(a+b) + b
// applied per block (block_size = 2^(log_d-layer), pair distance bsh=block_size/2),
// layers in REVERSE order (log_d-1 .. 0). Same twiddle schedule as the forward NTT.
#pragma once
#include "f128.cuh"
#include "ntt_host.hpp"

// One transposed-NTT layer. One thread per butterfly (2^(log_d-1) total).
__global__ void transposed_ntt_layer(F128* __restrict__ data, const F128* __restrict__ tw_basis,
                                    int layer, int log_d) {
    long long bsh = 1LL << (log_d - layer - 1);
    long long half_total = 1LL << (log_d - 1);
    long long idx = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= half_total) return;
    long long block = idx / bsh;
    long long j = idx - block * bsh;
    long long base = block * (bsh << 1);
    // twiddle(layer, block) = XOR of span basis at set bits of block.
    F128 t{0ull, 0ull};
    for (int k = 0; k < layer; k++) if ((block >> k) & 1ull) t = f128_add(t, tw_basis[k]);
    F128 a = data[base + j], b = data[base + j + bsh];
    F128 s = f128_add(a, b);
    data[base + j] = s;
    data[base + j + bsh] = f128_add(ghash_mul_karatsuba(t, s), b);
}

inline void launch_transpose_ntt(F128* d_data, const F128* d_tw, const TwiddleTable& tt,
                                 int log_d, int tpb = 256) {
    long long half = 1LL << (log_d - 1);
    long long blocks = (half + tpb - 1) / tpb;
    for (int layer = log_d - 1; layer >= 0; layer--)
        transposed_ntt_layer<<<(unsigned)blocks, tpb>>>(d_data, d_tw + tt.off[layer], layer, log_d);
}

// Scatter sparse weights into a zeroed domain: data[queries[i]] = w[i].
// queries are distinct (sample_distinct_queries), so no collisions.
__global__ void scatter_query_weights(F128* __restrict__ data, const unsigned long long* __restrict__ queries,
                                const F128* __restrict__ w, int n_queries) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n_queries) return;
    data[queries[i]] = w[i];
}
__global__ void clear_field_elements(F128* d, long long n) {
    long long i = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) d[i] = F128{0ull, 0ull};
}
