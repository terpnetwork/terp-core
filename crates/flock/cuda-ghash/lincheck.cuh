// Lincheck prover kernels — GPU port of src/lincheck.rs::prove_padded_inner.
//
// Lincheck reduces the zerocheck's two MLE claims â(x)=v_a, b̂(x)=v_b to a
// single z-claim. With k = 2^k_log (per-block width), n_log = m - k_log
// (#blocks), inner_rest_len = k_log - k_skip, the prover hot path is:
//
//   1. eq_inner = build_quirky_eq_table(z_skip, x_inner_rest, k_skip)   (len k)
//   2. comb_vec[c] = α·Σ_{r∈A_col[c]} eq_inner[r] + Σ_{r∈B_col[c]} eq_inner[r]
//      — the α-batched CSC column marginal (lincheck.rs::CscCircuit, no atomics:
//        one independent reduction per column).
//   3. z_vec[i] = Σ_{byte_idx} T_{byte_idx}[ z_packed[byte_idx·k + i] ]    (len k)
//      where T_{byte_idx} is the 256-entry sum table over the 8 eq_outer values
//      of stripe byte_idx (lincheck.rs::build_sum_table + partial_fold).
//   4. inner_rest_len rounds of TOP-BIT product-sumcheck on (comb_vec, z_vec):
//        msg (e1, einf) = (Σ C_hi·Z_hi, Σ (C_hi+C_lo)(Z_hi+Z_lo)) over the
//        (i, i+half) split; observe; sample r; fold both V[i] += r·(V[i+half]+V[i]).
//   5. z_partial = z_vec (len 2^k_skip); r_inner_skip sampled;
//      w = Σ lagrange(k_skip, r_inner_skip)·z_partial.
//
// Eq-table / lagrange builds come in a HOST form (f128_*_hd from ntt_host.hpp,
// the reference the tests check against) and a device form. Prefer the device
// form in provers: host GF(2^128) mul is ~350 ns, so a 2^18 eq table costs
// ~100 ms on the host and is free on hardware clmul.
#pragma once
#include "f128.cuh"
#include "ntt_host.hpp"
#include "phi8_table.cuh"
#include <vector>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

// Headers can't use each translation unit's own CK macro, and a silently failed
// setup call here would show up as a wrong z_vec, not as an error.
#define CK_LC(call) do { cudaError_t e_ = (call); if (e_ != cudaSuccess) { \
    printf("FATAL %s @ %s:%d\n", cudaGetErrorString(e_), __FILE__, __LINE__); exit(1); } } while (0)

#ifndef LC_TPB
#define LC_TPB 256
#endif
#ifndef LC_MAX_BLOCKS
#define LC_MAX_BLOCKS 2048
#endif

// ---------------------------------------------------------------------------
// Host eq-table / lagrange builders (mirror src/lincheck.rs + multilinear.rs).
// ---------------------------------------------------------------------------

// build_eq_table(point): out[i] = Π_j (1 + point[j] + bit_j(i)), LSB-first.
// Doubling-in-half (lincheck.rs:391).
inline std::vector<F128> build_eq_table_host(const std::vector<F128>& point) {
    const F128 ONE{1ull, 0ull};
    std::vector<F128> out;
    out.reserve((size_t)1 << point.size());
    out.push_back(ONE);
    for (size_t j = 0; j < point.size(); j++) {
        F128 r_j = point[j];
        F128 one_plus = f128_add_hd(ONE, r_j);
        size_t len = (size_t)1 << j;
        out.resize(2 * len);
        for (size_t i = 0; i < len; i++) {
            F128 v = out[i];
            out[i + len] = f128_mul_hd(v, r_j);
            out[i] = f128_mul_hd(v, one_plus);
        }
    }
    return out;
}

// lagrange_weights_naive(k_skip, z): φ8-basis Lagrange weights at z over the
// first ell = 2^k_skip nodes (multilinear.rs:77). ell <= 256.
// Lagrange weights w[i] = Π_{j≠i}(z+s_j) / Π_{j≠i}(s_i+s_j) over the skip domain
// S = {φ8(0..ell-1)}. S is an F2-subspace, so Z_S(x)=Π_{s}(x+s) is linearized and its
// derivative den_i = Π_{j≠i}(s_i+s_j) = Z_S'(s_i) = a0 is a CONSTANT (same for all i).
// Thus w[i] = (Z_S(z)/a0)·(z+s_i)^{-1}. With Montgomery batch inversion this is ~4·ell
// muls + 2 inversions instead of the naive O(ell²) muls + ell inversions (the latter
// was ~4 ms at ell=64, dominating the GPU zerocheck phase). Byte-identical output.
inline std::vector<F128> lagrange_weights_host(int k_skip, F128 z) {
    const F128 ONE{1ull, 0ull};
    size_t ell = (size_t)1 << k_skip;
    std::vector<F128> t(ell), pre(ell), w(ell);
    for (size_t i = 0; i < ell; i++) t[i] = f128_add_hd(z, PHI_8_TABLE[i]);   // z + s_i
    // num_i = Π_{j≠i}(z+s_j) via prefix·suffix products — NO field inversion.
    pre[0] = ONE;
    for (size_t i = 1; i < ell; i++) pre[i] = f128_mul_hd(pre[i - 1], t[i - 1]);  // Π_{j<i}
    // a0 = den_i (constant) = Π_{j≠0}(s_0 + s_j); z-independent, invert once per k_skip.
    static int s_cached_k = -1; static F128 s_a0inv{0, 0};
    if (s_cached_k != k_skip) {
        F128 s0 = PHI_8_TABLE[0], a0 = ONE;
        for (size_t j = 1; j < ell; j++) a0 = f128_mul_hd(a0, f128_add_hd(s0, PHI_8_TABLE[j]));
        s_a0inv = f128_inv_host(a0); s_cached_k = k_skip;
    }
    F128 suf = ONE;                                 // Π_{j>i}, accumulated in reverse
    for (size_t ii = ell; ii-- > 0; ) {
        w[ii] = f128_mul_hd(f128_mul_hd(pre[ii], suf), s_a0inv);   // num_i / a0
        suf = f128_mul_hd(suf, t[ii]);
    }
    return w;
}

// build_quirky_eq_table(z_skip, x_inner_rest, k_skip): length k = ell_skip·ell_rest,
// index = i_skip + i_rest·ell_skip, value = lambda_skip[i_skip]·eq_rest[i_rest]
// (lincheck.rs:1094).
inline std::vector<F128> build_quirky_eq_table_host(F128 z_skip,
                                                    const std::vector<F128>& x_inner_rest,
                                                    int k_skip) {
    std::vector<F128> lambda = lagrange_weights_host(k_skip, z_skip);
    std::vector<F128> eq_rest = build_eq_table_host(x_inner_rest);
    std::vector<F128> out;
    out.reserve(lambda.size() * eq_rest.size());
    for (F128 er : eq_rest)
        for (F128 ls : lambda)
            out.push_back(f128_mul_hd(ls, er));
    return out;
}

// Device build of the same quirky eq table, one thread per output element (no
// doubling): out[i_skip + i_rest·2^k_skip] = lambda[i_skip]·Π_j(bit_j(i_rest) ? c_j : 1+c_j).
// GF(2^128) mul is associative and commutative, so this is bit-identical to
// build_quirky_eq_table_host. The host builder is ~350 ns per mul (software
// carry-less mul); at k=2^14 that alone was milliseconds, and the whole table
// then had to be copied H2D. The lagrange weights stay on the host: 2^k_skip <=
// 256 entries and they need a field inversion.
__constant__ F128 g_qeq_lambda[256];
__constant__ F128 g_qeq_chal[64];
__global__ void build_quirky_equality_table(int k_skip, int d_rest, long long n, F128* __restrict__ out) {
    long long x = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    if (x >= n) return;
    long long i_rest = x >> k_skip;
    F128 acc = g_qeq_lambda[x & ((1LL << k_skip) - 1)];
    for (int j = 0; j < d_rest; j++) {
        F128 c = g_qeq_chal[j];
        F128 f = ((i_rest >> j) & 1) ? c : F128{c.lo ^ 1ull, c.hi};
        acc = ghash_mul_karatsuba(acc, f);
    }
    out[x] = acc;
}
inline void build_quirky_eq_device(F128* d_out, F128 z_skip,
                                   const std::vector<F128>& x_inner_rest, int k_skip, int tpb = 256) {
    std::vector<F128> lambda = lagrange_weights_host(k_skip, z_skip);
    cudaMemcpyToSymbol(g_qeq_lambda, lambda.data(), lambda.size() * sizeof(F128));
    if (!x_inner_rest.empty())
        cudaMemcpyToSymbol(g_qeq_chal, x_inner_rest.data(), x_inner_rest.size() * sizeof(F128));
    long long n = (long long)lambda.size() << x_inner_rest.size();
    build_quirky_equality_table<<<(unsigned)((n + tpb - 1) / tpb), tpb>>>(k_skip, (int)x_inner_rest.size(), n, d_out);
}

// inner_product over equal-length F128 slices (for the final w on the host).
inline F128 inner_product_host(const std::vector<F128>& a, const std::vector<F128>& b) {
    F128 acc{0ull, 0ull};
    for (size_t i = 0; i < a.size(); i++) acc = f128_add_hd(acc, f128_mul_hd(a[i], b[i]));
    return acc;
}

// ---------------------------------------------------------------------------
// Step 2: α-batched CSC column-marginal fold → comb_vec (one WARP / column).
// ---------------------------------------------------------------------------
// One WARP per column. The obvious thread-per-column shape loses three ways at
// BLAKE3's dimensions (16384 columns, 21M nonzeros, mean 1283/col):
//   - the grid is 16384 threads = 64 blocks, so 106 of a 170-SM GPU's SMs idle.
//     Per-SM theoretical occupancy is 100% and cannot see this.
//   - each lane walks its own column, so a warp touches 32 scattered 4-byte
//     row indices per step instead of one coalesced 128-byte line.
//   - column lengths are ragged (median 916, max 13869); a warp runs at its
//     slowest lane, measured at 1.36x the useful work.
// Striding the lanes across ONE column's nonzeros fixes all three: reads
// coalesce, every lane in a warp does equal work, and the grid becomes 2048
// blocks. XOR-sum is order-independent, so the shuffle reduction is bit-identical.
__global__ void linear_check_compressed_column_fold(const F128* __restrict__ eq_inner,
                                  const uint32_t* __restrict__ a_col_ptr,
                                  const uint32_t* __restrict__ a_rows,
                                  const uint32_t* __restrict__ b_col_ptr,
                                  const uint32_t* __restrict__ b_rows,
                                  F128 alpha, int n_cols, F128* __restrict__ comb) {
    int c = (int)((blockIdx.x * blockDim.x + threadIdx.x) >> 5);   // one column per warp
    int lane = threadIdx.x & 31;
    if (c >= n_cols) return;              // whole warp exits together: shfl mask stays full
    F128 sa{0, 0};
    for (uint32_t j = a_col_ptr[c] + lane; j < a_col_ptr[c + 1]; j += 32)
        sa = f128_add(sa, eq_inner[a_rows[j]]);
    F128 sb{0, 0};
    for (uint32_t j = b_col_ptr[c] + lane; j < b_col_ptr[c + 1]; j += 32)
        sb = f128_add(sb, eq_inner[b_rows[j]]);
#pragma unroll
    for (int off = 16; off > 0; off >>= 1) {
        sa.lo ^= __shfl_down_sync(0xffffffffu, sa.lo, off);
        sa.hi ^= __shfl_down_sync(0xffffffffu, sa.hi, off);
        sb.lo ^= __shfl_down_sync(0xffffffffu, sb.lo, off);
        sb.hi ^= __shfl_down_sync(0xffffffffu, sb.hi, off);
    }
    if (lane == 0) comb[c] = f128_add(ghash_mul_karatsuba(alpha, sa), sb);
}

inline void launch_linear_check_compressed_column_fold(const F128* d_eq_inner,
                                     const uint32_t* d_a_col_ptr, const uint32_t* d_a_rows,
                                     const uint32_t* d_b_col_ptr, const uint32_t* d_b_rows,
                                     F128 alpha, int n_cols, F128* d_comb) {
    long long threads = (long long)n_cols * 32;            // one warp per column
    int blocks = (int)((threads + LC_TPB - 1) / LC_TPB);
    linear_check_compressed_column_fold<<<blocks, LC_TPB>>>(d_eq_inner, d_a_col_ptr, d_a_rows,
                                          d_b_col_ptr, d_b_rows, alpha, n_cols, d_comb);
}

// ---------------------------------------------------------------------------
// Step 3: partial fold of the packed witness → z_vec, via per-stripe sum tables
// built in SHARED memory (the CPU's strategy). No giant global sum-table: each
// block builds a stripe's 256-entry table in shared mem once, then all its
// i_inner threads do a shared-mem lookup. The witness is the only large buffer
// read, and it's read once, coalesced — nothing else touches DRAM.
//
// Decomposition: a block owns a tile of LC_PF_BK = 2048 i_inner (256 threads ×
// 8 each) and a share of the stripes (grid.y = G stripe-groups for parallelism
// when k is small). Per stripe: build tbl[256] from the 8 eq_outer values, then
// each thread folds its (up to 8) bytes.
//
// This kernel is L1TEX-bound (~87% of peak; DRAM only ~42%) and the tbl[byte]
// gather is most of that. Over half those wavefronts are bank conflicts, and they
// are not removable by re-laying-out the table: a random gather always puts as
// many lanes in a phase as there are bank groups to hit (8 lanes / 8 quads at 16 B
// per entry, 16/16 at 8 B, 32/32 at 4 B), so every element width pays the same
// ~3x. Fewer, wider lookups would need a 12-bit table, whose per-stripe build
// costs an order of magnitude more than it saves.
//
// Stripe-groups merge into z_vec with atomicXor, not a G·k partials buffer and a
// reduce pass. XOR is associative and commutative and the field add is exact, so
// the result is bit-identical whatever order the groups land in. z_vec is 256 KB
// — the whole atomic working set stays L2-resident, so the merge costs no DRAM
// traffic, whereas the partials buffer cost G·k·16 bytes written and read again
// (256 MB each way at m=33, a fifth of this kernel's total traffic).
#define LC_PF_THREADS 256
#define LC_PF_ACC 8                            // measured best; 4 and 16 both lose
#define LC_PF_BK (LC_PF_THREADS * LC_PF_ACC)   // i_inner per block = 2048

__global__ void __launch_bounds__(LC_PF_THREADS)
linear_check_partial_fold_shared(const uint8_t* __restrict__ z_packed,
                             const F128* __restrict__ eq_outer,
                             long long n_stripes, int k, int useful_bits,
                             F128* __restrict__ z_vec) {
    __shared__ F128 tbl[256];
    __shared__ F128 nib[32];        // [0,16) low-nibble sums, [16,32) high-nibble
    int tx = threadIdx.x;
    int i0 = blockIdx.x * LC_PF_BK;
    F128 acc[LC_PF_ACC];
#pragma unroll
    for (int j = 0; j < LC_PF_ACC; j++) acc[j] = F128{0, 0};

    // Interleaved, not blocked: group g takes stripes g, g+G, g+2G, ... Every group
    // then gets the same stripe count to within one, with no tail group and no
    // start/end bookkeeping, and concurrent groups read neighbouring stripes rather
    // than addresses a fixed large stride apart.
    for (long long s = blockIdx.y; s < n_stripes; s += gridDim.y) {
        // Build the stripe's 256-entry sum table, tbl[e] = Σ_{r: bit r of e set}
        // eq_outer[8s+r], one entry per thread. Going via nibble halves rather than
        // having all 256 threads read all 8 eq values: a broadcast LDS.128 still
        // has to deliver 16 B to each of 32 lanes, so those 8 reads cost as much as
        // 8 wavefronts per warp — a quarter of this kernel's shared traffic. The two
        // nib[] lookups replacing them are indexed by tx, not by data, so each phase
        // of 8 lanes hits 8 distinct bank quads and they run conflict-free.
        __syncthreads();                     // previous stripe's tbl readers are done
        if (tx < 32) {
            int base = (tx < 16) ? 0 : 4, n = tx & 15;
            F128 v{0, 0};
#pragma unroll
            for (int r = 0; r < 4; r++)
                if ((n >> r) & 1) v = f128_add(v, eq_outer[8 * s + base + r]);
            nib[tx] = v;
        }
        __syncthreads();
        tbl[tx] = f128_add(nib[tx & 15], nib[16 + (tx >> 4)]);
        __syncthreads();
#pragma unroll
        for (int j = 0; j < LC_PF_ACC; j++) {
            int i_inner = i0 + tx + j * LC_PF_THREADS;
            if (i_inner < useful_bits) {
                uint8_t byte = z_packed[s * (long long)k + i_inner];
                acc[j] = f128_add(acc[j], tbl[byte]);
            }
        }
    }
#pragma unroll
    for (int j = 0; j < LC_PF_ACC; j++) {
        int i_inner = i0 + tx + j * LC_PF_THREADS;
        if (i_inner < useful_bits) {
            atomicXor((unsigned long long*)&z_vec[i_inner].lo, (unsigned long long)acc[j].lo);
            atomicXor((unsigned long long*)&z_vec[i_inner].hi, (unsigned long long)acc[j].hi);
        }
    }
}

// d_eq_outer holds 2^n_log = 8*n_stripes. z_vec is the accumulator, so it is
// zeroed first — which also supplies the zeros for i_inner in [useful_bits, k).
inline void launch_linear_check_partial_fold(const uint8_t* d_z_packed, const F128* d_eq_outer,
                                         long long n_stripes, int k, int useful_bits,
                                         F128* d_z_vec) {
    int x_tiles = (k + LC_PF_BK - 1) / LC_PF_BK;     // i_inner tiles per stripe-group

    // Stripe-groups G: each block walks its stripes serially, so G only has to make
    // x_tiles·G fill the SMs. Runtime is flat from 4 to 64 blocks/SM, so aim for 32
    // — deep enough that a partial last wave is a rounding error, shallow enough to
    // keep atomic contention on z_vec low. x_tiles is a power of two, so this comes
    // out an exact multiple of the SM count; a grid that misses by a fraction of a
    // block per SM leaves one straggler wave holding up all the others (~15% at 6).
    static int s_sms = 0;
    if (!s_sms) CK_LC(cudaDeviceGetAttribute(&s_sms, cudaDevAttrMultiProcessorCount, 0));
    long long G = ((long long)s_sms * 32 + x_tiles - 1) / x_tiles;
    if (G > n_stripes) G = n_stripes;

    CK_LC(cudaMemsetAsync(d_z_vec, 0, (size_t)k * sizeof(F128)));
    dim3 grid((unsigned)x_tiles, (unsigned)G);
    linear_check_partial_fold_shared<<<grid, LC_PF_THREADS>>>(d_z_packed, d_eq_outer, n_stripes,
                                                          k, useful_bits, d_z_vec);
}

// ---------------------------------------------------------------------------
// Step 4: TOP-BIT product-sumcheck round message + fold.
//   message: e1   = Σ_{i<half} C[i+half]·Z[i+half]                (= q(1))
//            einf = Σ_{i<half} (C[i+half]+C[i])·(Z[i+half]+Z[i])  (= q(∞))
//   fold:    V'[i] = V[i] + r·(V[i+half]+V[i])     (applied to both C and Z)
// ---------------------------------------------------------------------------
__global__ void linear_check_message_partial(const F128* __restrict__ C, const F128* __restrict__ Z,
                                     long long half, F128* p1, F128* pinf) {
    __shared__ F128 s1[LC_TPB];
    __shared__ F128 sinf[LC_TPB];
    long long t = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    long long stride = (long long)gridDim.x * blockDim.x;
    F128 e1{0, 0}, einf{0, 0};
    for (long long i = t; i < half; i += stride) {
        F128 clo = C[i], chi = C[i + half];
        F128 zlo = Z[i], zhi = Z[i + half];
        e1 = f128_add(e1, ghash_mul_karatsuba(chi, zhi));
        einf = f128_add(einf, ghash_mul_karatsuba(f128_add(chi, clo), f128_add(zhi, zlo)));
    }
    int x = threadIdx.x;
    s1[x] = e1; sinf[x] = einf;
    __syncthreads();
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (x < s) { s1[x] = f128_add(s1[x], s1[x + s]); sinf[x] = f128_add(sinf[x], sinf[x + s]); }
        __syncthreads();
    }
    if (x == 0) { p1[blockIdx.x] = s1[0]; pinf[blockIdx.x] = sinf[0]; }
}

// One 256-thread block (was a single-thread loop, ~200 us at 2048 blocks; bit-identical).
__global__ void combine_linear_check_message(const F128* p1, const F128* pinf, int blocks,
                                     F128* e1_out, F128* einf_out) {
    __shared__ F128 s1[LC_TPB];
    __shared__ F128 sinf[LC_TPB];
    F128 a1{0, 0}, ainf{0, 0};
    for (int b = threadIdx.x; b < blocks; b += blockDim.x) { a1 = f128_add(a1, p1[b]); ainf = f128_add(ainf, pinf[b]); }
    int x = threadIdx.x;
    s1[x] = a1; sinf[x] = ainf;
    __syncthreads();
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (x < s) { s1[x] = f128_add(s1[x], s1[x + s]); sinf[x] = f128_add(sinf[x], sinf[x + s]); }
        __syncthreads();
    }
    if (x == 0) { *e1_out = s1[0]; *einf_out = sinf[0]; }
}

// Fold one table at r over the top-bit split: Vo[i] = V[i] + r·(V[i+half]+V[i]).
__global__ void linear_check_fold(const F128* __restrict__ V, F128* __restrict__ Vo,
                                  long long half, F128 r) {
    long long i = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= half) return;
    F128 lo = V[i], hi = V[i + half];
    Vo[i] = f128_add(lo, ghash_mul_karatsuba(r, f128_add(hi, lo)));
}

// Fold BOTH tables (comb_vec, z_vec) at r in one launch — they fold in lockstep
// at the same r, so a single kernel halves the per-round fold launch overhead.
__global__ void linear_check_fold_pair(const F128* __restrict__ C, const F128* __restrict__ Z,
                                   F128* __restrict__ Co, F128* __restrict__ Zo,
                                   long long half, F128 r) {
    long long i = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= half) return;
    F128 cl = C[i], chh = C[i + half];
    Co[i] = f128_add(cl, ghash_mul_karatsuba(r, f128_add(chh, cl)));
    F128 zl = Z[i], zh = Z[i + half];
    Zo[i] = f128_add(zl, ghash_mul_karatsuba(r, f128_add(zh, zl)));
}

inline int lincheck_blocks(long long half) {
    long long b = (half + LC_TPB - 1) / LC_TPB;
    if (b < 1) b = 1;
    if (b > LC_MAX_BLOCKS) b = LC_MAX_BLOCKS;
    return (int)b;
}

// One round's message over (dC, dZ): leaves (e1, einf) on device. d_p1/d_pinf
// are scratch of length >= LC_MAX_BLOCKS.
inline void launch_linear_check_message(const F128* dC, const F128* dZ, long long half,
                                F128* d_p1, F128* d_pinf, F128* d_e1, F128* d_einf) {
    int blocks = lincheck_blocks(half);
    linear_check_message_partial<<<blocks, LC_TPB>>>(dC, dZ, half, d_p1, d_pinf);
    combine_linear_check_message<<<1, LC_TPB>>>(d_p1, d_pinf, blocks, d_e1, d_einf);
}

inline void launch_linear_check_fold(const F128* dV, F128* dVo, long long half, F128 r) {
    long long blocks = (half + LC_TPB - 1) / LC_TPB; if (blocks < 1) blocks = 1;
    linear_check_fold<<<(unsigned)blocks, LC_TPB>>>(dV, dVo, half, r);
}

// Fold comb_vec and z_vec together at r (one launch).
inline void launch_linear_check_fold_pair(const F128* dC, const F128* dZ, F128* dCo, F128* dZo,
                                  long long half, F128 r) {
    long long blocks = (half + LC_TPB - 1) / LC_TPB; if (blocks < 1) blocks = 1;
    linear_check_fold_pair<<<(unsigned)blocks, LC_TPB>>>(dC, dZ, dCo, dZo, half, r);
}
