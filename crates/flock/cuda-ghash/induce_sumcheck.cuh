// induce_sumcheck_poly — step 4 of the GPU pcs::open (Ligerito) port
// for the GPU Ligerito open. Port of src/pcs/ligerito.rs::induce_sumcheck_poly: build
// the induced basis poly (length n = 2^log_msg_cols) from the opened query rows.
//
// Split (correctness-first):
//   HOST setup (small, O(n_queries·(√n + num_interleaved))) — faithfully
//   reimplemented from the Rust, validated transitively by the bit-exact
//   basis_poly check: inv_sks_vks (Fermat), alpha_pows = build_eq_table(alpha),
//   eq = build_eq_table(v_challenges), enforced_sum, and per query the
//   novel-basis tensor w[k] = s_k(query)·inv_sks_vks[k] (s_k chain via next_s)
//   split into low/high sub-tensors, with scaled_high[i][h] = alpha_pows[i]·high_i[h].
//   DEVICE accumulate (dominant, O(n·n_queries)) — one thread per output:
//     basis_poly[h·low_n + l] = Σ_i scaled_high[i][h] · low_i[l]
//   reduce-per-term (F128). Deferred reduction (F256) was measured a wash-to-
//   slight-loss here, so it's not used.
#pragma once
#include <vector>
#include "f128.cuh"
#include "ntt_host.hpp"   // host F128 math: f128_add_hd/f128_mul_hd/f128_inv_host

// ---- host helpers (mirror the Rust) --------------------------------------

inline F128 next_s_hd(F128 s, F128 s_at_root) {
    // next_s(s, v) = s*s + v*s
    return f128_add_hd(f128_mul_hd(s, s), f128_mul_hd(s_at_root, s));
}

// Port of ligerito.rs::eval_sk_at_vks(log_n) — the basis constants sks_vks[k] =
// s_k(v_k), length log_n+1. Only depends on log_n.
inline std::vector<F128> eval_sk_at_vks_hd(int log_n) {
    std::vector<F128> sks(log_n + 1, F128{0ull, 0ull});
    sks[0] = F128{1ull, 0ull};
    if (log_n == 0) return sks;
    std::vector<F128> layer(log_n);
    for (int i = 0; i < log_n; i++) layer[i] = F128{1ull << (i + 1), 0ull}; // (1..=log_n)
    int cur_len = log_n;
    for (int i = 0; i < log_n; i++) {
        for (int j = 0; j < cur_len; j++) {
            F128 sk_at_vk = next_s_hd(layer[j], sks[i]);
            if (j == 0) sks[i + 1] = sk_at_vk; else layer[j - 1] = sk_at_vk;
        }
        cur_len -= 1;
    }
    return sks;
}

// build_eq_table(point): LSB-first eq tensor (lincheck.rs:391).
inline std::vector<F128> build_eq_table_hd(const std::vector<F128>& point) {
    int d = (int)point.size();
    std::vector<F128> out;
    out.reserve((size_t)1 << d);
    out.push_back(F128{1ull, 0ull});
    for (int j = 0; j < d; j++) {
        F128 r = point[j];
        F128 opr = f128_add_hd(F128{1ull, 0ull}, r);
        int len = 1 << j;
        out.resize((size_t)2 * len, F128{0ull, 0ull});
        for (int i = 0; i < len; i++) {
            F128 v = out[i];
            out[i + len] = f128_mul_hd(v, r);
            out[i] = f128_mul_hd(v, opr);
        }
    }
    return out;
}

// ---- device eq-table builder (hardware clmad, replaces host build_eq_table_hd
// for the big OOD eq) ----
__global__ void double_equality_table(F128* out, F128 r, F128 opr, long long len) {
    long long i = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= len) return;
    F128 v = out[i];
    out[i + len] = ghash_mul_karatsuba(v, r);     // child bit=1
    out[i]       = ghash_mul_karatsuba(v, opr);    // child bit=0
}
// Single-kernel eq builder: eq[x] = Π_j (bit j of x ? r_j : 1+r_j). Replaces the
// d-launch doubling (one kernel per level) with ONE launch — that launch overhead
// dominated the zerocheck tail (23 rounds × up-to-22 launches each). Challenges in
// __constant__ (per-step broadcast). Bit-identical to the doubling.
__constant__ F128 g_eq_chal[64];
__global__ void build_equality_table_directly(int d, long long n, F128* __restrict__ out) {
    long long x = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    if (x >= n) return;
    F128 acc{1ull, 0ull};
    for (int j = 0; j < d; j++) {
        F128 c = g_eq_chal[j];
        F128 f = ((x >> j) & 1) ? c : F128{c.lo ^ 1ull, c.hi};
        acc = ghash_mul_karatsuba(acc, f);
    }
    out[x] = acc;
}
// Build the length-2^d eq table on device into d_out. `challenges` is a host
// array of `d` points. Hybrid: the doubling is compute-optimal (2^d muls) but costs
// d launches; the direct kernel is 1 launch but d·2^d muls. So use the single direct
// kernel for SMALL d (launch-bound: the many tiny tail rounds) and doubling for BIG d
// (compute-bound: round-1/round-2 eq). Bit-identical either way.
inline void build_eq_device(F128* d_out, const F128* challenges, int d, int tpb = 256) {
    if (d <= 0) { F128 one{1ull, 0ull}; (void)cudaMemcpy(d_out, &one, sizeof(F128), cudaMemcpyHostToDevice); return; }
    if (d <= 12) {
        cudaMemcpyToSymbol(g_eq_chal, challenges, (size_t)d * sizeof(F128));
        long long n = 1LL << d;
        build_equality_table_directly<<<(unsigned)((n + tpb - 1) / tpb), tpb>>>(d, n, d_out);
        return;
    }
    F128 one{1ull, 0ull};
    (void)cudaMemcpy(d_out, &one, sizeof(F128), cudaMemcpyHostToDevice);
    for (int j = 0; j < d; j++) {
        F128 r = challenges[j];
        F128 opr{r.lo ^ 1ull, r.hi};
        long long len = 1LL << j;
        double_equality_table<<<(unsigned)((len + tpb - 1) / tpb), tpb>>>(d_out, r, opr, len);
    }
}

// Result of host setup: device-ready flat tensors + scalar enforced_sum.
struct InduceSetup {
    std::vector<F128> low;          // n_queries * low_n
    std::vector<F128> scaled_high;  // n_queries * high_n  (alpha_pows[i] * high_i[h])
    int low_n = 0, high_n = 0, n_queries = 0;
    long long n = 0;
    F128 enforced_sum{0ull, 0ull};
};

// Reproduce induce_sumcheck_poly's host-side setup. `sks_vks` has length
// log_n+1; `queries[i]` are positions; `opened_rows` is n_queries*num_interleaved.
inline InduceSetup induce_setup(int log_n,
                                const std::vector<F128>& sks_vks,
                                const std::vector<F128>& v_challenges,
                                const std::vector<F128>& alpha,
                                const std::vector<unsigned long long>& queries,
                                const std::vector<F128>& opened_rows,
                                int num_interleaved) {
    InduceSetup S;
    S.n_queries = (int)queries.size();
    S.n = 1LL << log_n;
    int low_bits = log_n / 2;
    int high_bits = log_n - low_bits;
    S.low_n = 1 << low_bits;
    S.high_n = 1 << high_bits;

    std::vector<F128> inv_sks_vks(log_n);
    for (int k = 0; k < log_n; k++) {
        F128 v = sks_vks[k];
        inv_sks_vks[k] = (v.lo == 0 && v.hi == 0) ? F128{0ull, 0ull} : f128_inv_host(v);
    }

    std::vector<F128> eq = build_eq_table_hd(v_challenges);                 // num_interleaved
    std::vector<F128> alpha_pows = build_eq_table_hd(alpha);                // >= n_queries
    alpha_pows.resize(S.n_queries);

    // enforced_sum = Σ_i alpha_pows[i] · ⟨row_i, eq⟩
    F128 esum{0ull, 0ull};
    for (int i = 0; i < S.n_queries; i++) {
        F128 dot{0ull, 0ull};
        const F128* row = &opened_rows[(size_t)i * num_interleaved];
        for (int t = 0; t < num_interleaved; t++)
            dot = f128_add_hd(dot, f128_mul_hd(row[t], eq[t]));
        esum = f128_add_hd(esum, f128_mul_hd(dot, alpha_pows[i]));
    }
    S.enforced_sum = esum;

    S.low.assign((size_t)S.n_queries * S.low_n, F128{0ull, 0ull});
    S.scaled_high.assign((size_t)S.n_queries * S.high_n, F128{0ull, 0ull});

    std::vector<F128> w(log_n), low(S.low_n), high(S.high_n);
    for (int i = 0; i < S.n_queries; i++) {
        F128 x = F128{queries[i], 0ull};
        F128 s = x;
        w[0] = f128_mul_hd(s, inv_sks_vks[0]);
        for (int k = 1; k < log_n; k++) {
            s = next_s_hd(s, sks_vks[k - 1]);
            w[k] = f128_mul_hd(s, inv_sks_vks[k]);
        }
        low.assign(S.low_n, F128{0ull, 0ull});
        low[0] = F128{1ull, 0ull};
        for (int k = 0; k < low_bits; k++) {
            F128 wk = w[k];
            int cur = 1 << k;
            for (int j = 0; j < cur; j++) low[j + cur] = f128_mul_hd(wk, low[j]);
        }
        high.assign(S.high_n, F128{0ull, 0ull});
        high[0] = F128{1ull, 0ull};
        for (int k = 0; k < high_bits; k++) {
            F128 wk = w[low_bits + k];
            int cur = 1 << k;
            for (int j = 0; j < cur; j++) high[j + cur] = f128_mul_hd(wk, high[j]);
        }
        for (int l = 0; l < S.low_n; l++) S.low[(size_t)i * S.low_n + l] = low[l];
        for (int h = 0; h < S.high_n; h++)
            S.scaled_high[(size_t)i * S.high_n + h] = f128_mul_hd(alpha_pows[i], high[h]);
    }
    return S;
}

// ---- device per-query w-chain (replaces the host software-mul s_k chain) ---
// One thread per query: w[i][k] = s_k(query_i)·inv_sks[k], s_0=query, s_k via
// next_s (s² + sks_vks[k-1]·s). Hardware clmad.
__global__ void compute_query_weights(const unsigned long long* __restrict__ queries,
                                 const F128* __restrict__ sks_vks, const F128* __restrict__ inv_sks,
                                 int n_total, int n_queries, F128* __restrict__ w_out) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n_queries) return;
    F128 s = F128{queries[i], 0ull};
    w_out[(size_t)i * n_total + 0] = ghash_mul_karatsuba(s, inv_sks[0]);
    for (int k = 1; k < n_total; k++) {
        F128 ss = ghash_mul_karatsuba(s, s);
        F128 vs = ghash_mul_karatsuba(sks_vks[k - 1], s);
        s = f128_add(ss, vs);
        w_out[(size_t)i * n_total + k] = ghash_mul_karatsuba(s, inv_sks[k]);
    }
}

// ---- device qtensor build (replaces the host software-mul doubling) -------
// One block per query: build low[low_n] + high[high_n] in shared memory via the
// novel-basis doubling, then write low and scaled_high = alpha_pows[i]·high.
__global__ void build_query_tensors(const F128* __restrict__ w, const F128* __restrict__ alpha_pows,
                                      int n_total, int low_bits, int high_bits,
                                      F128* __restrict__ d_low, F128* __restrict__ d_sh) {
    extern __shared__ F128 sh[];
    int i = blockIdx.x;
    int low_n = 1 << low_bits, high_n = 1 << high_bits;
    F128* low = sh;
    F128* high = sh + low_n;
    int t = threadIdx.x;
    if (t == 0) { low[0] = F128{1ull, 0ull}; high[0] = F128{1ull, 0ull}; }
    __syncthreads();
    for (int k = 0; k < low_bits; k++) {
        int cur = 1 << k; F128 wk = w[(size_t)i * n_total + k];
        for (int j = t; j < cur; j += blockDim.x) low[j + cur] = ghash_mul_karatsuba(wk, low[j]);
        __syncthreads();
    }
    for (int k = 0; k < high_bits; k++) {
        int cur = 1 << k; F128 wk = w[(size_t)i * n_total + low_bits + k];
        for (int j = t; j < cur; j += blockDim.x) high[j + cur] = ghash_mul_karatsuba(wk, high[j]);
        __syncthreads();
    }
    for (int l = t; l < low_n; l += blockDim.x) d_low[(size_t)i * low_n + l] = low[l];
    F128 ap = alpha_pows[i];
    for (int h = t; h < high_n; h += blockDim.x) d_sh[(size_t)i * high_n + h] = ghash_mul_karatsuba(ap, high[h]);
}

// Device induce setup: cheap parts (inv_sks_vks, per-query w chain, alpha_pows,
// enforced_sum) on host; the O(n_queries·√n) tensor build on device. Returns
// device d_low / d_sh and enforced_sum; caller frees d_low/d_sh.
struct InduceSetupDev {
    F128 *d_low = nullptr, *d_sh = nullptr;
    int low_n = 0, high_n = 0, n_queries = 0;
    long long n = 0;
    F128 enforced_sum{0ull, 0ull};
};

inline InduceSetupDev induce_setup_device(int log_n, const std::vector<F128>& sks_vks,
                                          const std::vector<F128>& v_challenges,
                                          const std::vector<F128>& alpha,
                                          const std::vector<unsigned long long>& queries,
                                          const std::vector<F128>& opened_rows, int num_interleaved) {
    InduceSetupDev S;
    S.n_queries = (int)queries.size();
    S.n = 1LL << log_n;
    int low_bits = log_n / 2, high_bits = log_n - low_bits;
    S.low_n = 1 << low_bits; S.high_n = 1 << high_bits;

    std::vector<F128> inv_sks(log_n);
    for (int k = 0; k < log_n; k++) { F128 v = sks_vks[k]; inv_sks[k] = (v.lo==0&&v.hi==0)?F128{0ull,0ull}:f128_inv_host(v); }
    std::vector<F128> eq = build_eq_table_hd(v_challenges);
    std::vector<F128> alpha_pows = build_eq_table_hd(alpha); alpha_pows.resize(S.n_queries);

    // enforced_sum (host, small — independent of the w-chain).
    F128 esum{0ull, 0ull};
    for (int i = 0; i < S.n_queries; i++) {
        F128 dot{0ull,0ull};
        const F128* row = &opened_rows[(size_t)i * num_interleaved];
        for (int t = 0; t < num_interleaved; t++) dot = f128_add_hd(dot, f128_mul_hd(row[t], eq[t]));
        esum = f128_add_hd(esum, f128_mul_hd(dot, alpha_pows[i]));
    }
    S.enforced_sum = esum;

    // w-chain on device (hardware clmad).
    F128 *d_w, *d_ap, *d_sks, *d_inv; unsigned long long* d_q;
    (void)cudaMalloc(&d_w, (size_t)S.n_queries*log_n*sizeof(F128));
    (void)cudaMalloc(&d_ap, S.n_queries*sizeof(F128));
    (void)cudaMalloc(&d_sks, log_n*sizeof(F128));
    (void)cudaMalloc(&d_inv, log_n*sizeof(F128));
    (void)cudaMalloc(&d_q, S.n_queries*sizeof(unsigned long long));
    (void)cudaMalloc(&S.d_low, (size_t)S.n_queries*S.low_n*sizeof(F128));
    (void)cudaMalloc(&S.d_sh, (size_t)S.n_queries*S.high_n*sizeof(F128));
    (void)cudaMemcpy(d_ap, alpha_pows.data(), S.n_queries*sizeof(F128), cudaMemcpyHostToDevice);
    (void)cudaMemcpy(d_sks, sks_vks.data(), log_n*sizeof(F128), cudaMemcpyHostToDevice);
    (void)cudaMemcpy(d_inv, inv_sks.data(), log_n*sizeof(F128), cudaMemcpyHostToDevice);
    (void)cudaMemcpy(d_q, queries.data(), S.n_queries*sizeof(unsigned long long), cudaMemcpyHostToDevice);
    compute_query_weights<<<(S.n_queries+255)/256, 256>>>(d_q, d_sks, d_inv, log_n, S.n_queries, d_w);
    size_t shmem = (size_t)(S.low_n + S.high_n) * sizeof(F128);
    build_query_tensors<<<S.n_queries, 256, shmem>>>(d_w, d_ap, log_n, low_bits, high_bits, S.d_low, S.d_sh);
    cudaFree(d_w); cudaFree(d_ap); cudaFree(d_sks); cudaFree(d_inv); cudaFree(d_q);
    return S;
}

// ---- device accumulation -------------------------------------------------

// basis_poly[p] = Σ_i scaled_high[i*high_n + (p/low_n)] · low[i*low_n + (p%low_n)]
__global__ void induce_accumulate(const F128* __restrict__ scaled_high,
                                  const F128* __restrict__ low,
                                  int n_queries, int low_n, int high_n,
                                  F128* __restrict__ basis_poly, long long n) {
    long long p = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    if (p >= n) return;
    int h = (int)(p / low_n);
    int l = (int)(p - (long long)h * low_n);
    // Reduce-per-term: ghash_reduce is cheap and pipelines behind the CLMAD
    // multiply on this GPU, so deferring it (F256 accumulate) was a measured wash-
    // to-slight-loss — plain F128 accumulation is simpler and marginally faster.
    F128 acc{0, 0};
    for (int i = 0; i < n_queries; i++) {
        F128 sh = scaled_high[(size_t)i * high_n + h];
        F128 lv = low[(size_t)i * low_n + l];
        acc = f128_add(acc, ghash_mul_karatsuba(sh, lv));
    }
    basis_poly[p] = acc;
}

inline void launch_induce_accumulate(const F128* d_scaled_high, const F128* d_low,
                                     int n_queries, int low_n, int high_n,
                                     F128* d_basis, long long n, int tpb = 256) {
    long long blocks = (n + tpb - 1) / tpb;
    induce_accumulate<<<(unsigned)blocks, tpb>>>(d_scaled_high, d_low, n_queries,
                                                 low_n, high_n, d_basis, n);
}
