// Interleaved additive (LCH) NTT over GF(2^128) on CUDA.
//
// Direct port of the scalar reference in
//   src/ntt/additive_ntt_f128.rs
// specifically `forward_transform_interleaved_scalar_from_layer` (the butterfly)
// and the twiddle schedule. Correctness-first: one layer per kernel launch,
// global memory, SoA layout `data[pos * num_ntts + lane]`. No shared-mem tiling
// / layer fusion yet — those are the P2 "then optimize" step, gated on this
// matching the oracle.
//
// THE one correctness risk per the plan is the twiddle schedule. Two facts pin
// it down (see src/pcs/commit.rs:270):
//   * the NTT is built with dim == k_code, and the per-lane buffer is 2^k_code,
//     so the basis length L == log_d. twiddle uses evals[L - layer - 1][1..].
//   * the 0-th element of each evals row is the normalized 1 and is "absorbed"
//     into the butterfly, hence the [1..] slice in the twiddle span.
// The twiddle table is built on the host (ntt_host.hpp) and validated on the
// CPU against the flare oracle (host_check_ntt.cpp) before this kernel runs.
//
// Field arithmetic: the device butterfly uses `ghash_mul_karatsuba` from
// f128.cuh — 3 carryless products (6 CLMAD) + reduction, the fastest multiply
// on this GPU in the bench_f128 experiments.
#pragma once
#include "f128.cuh"
#include "ntt_host.hpp"   // F128/u64 from f128.cuh above; host twiddle build

// ---------------------------------------------------------------------------
// One forward NTT layer over the interleaved SoA buffer. One thread per
// butterfly *lane* (block, row, lane). `tw_basis` points at layer `l`'s span
// basis (TwiddleTable::data + off[l]); it has `layer` entries.
//
// Matches the scalar reference exactly:
//   block_size = 1 << (log_d - layer);  half = block_size / 2
//   off_top = block*block_size*num_ntts + row*num_ntts + lane
//   off_bot = off_top + half*num_ntts
//   new_u = top + v*tw;  bot = v + new_u
// ---------------------------------------------------------------------------
__global__ void additive_ntt_layer(F128* data, const F128* tw_basis,
                                 int layer, int log_d, int num_ntts) {
    long long half    = 1LL << (log_d - layer - 1);
    long long pairs   = half * (long long)num_ntts;      // butterfly lanes per block
    long long nblocks = 1LL << layer;
    long long total   = nblocks * pairs;

    long long tid = blockIdx.x * (long long)blockDim.x + threadIdx.x;
    if (tid >= total) return;

    long long block = tid / pairs;
    long long rem   = tid - block * pairs;
    long long row   = rem / num_ntts;
    long long lane  = rem - row * num_ntts;

    // twiddle(layer, block) = XOR of span-basis elements at set bits of block.
    F128 tw{0ull, 0ull};
    for (int j = 0; j < layer; j++) {
        if ((block >> j) & 1ull) tw = f128_add(tw, tw_basis[j]);
    }

    long long block_size  = half << 1;
    long long block_start = block * block_size * (long long)num_ntts;
    long long off_top = block_start + row * (long long)num_ntts + lane;
    long long off_bot = off_top + half * (long long)num_ntts;

    F128 v = data[off_bot];
    F128 u = f128_add(data[off_top], ghash_mul_karatsuba(v, tw));
    data[off_top] = u;
    data[off_bot] = f128_add(v, u);
}

// ---------------------------------------------------------------------------
// Multi-layer fusion. At realistic m the single-layer kernel is HBM-bound: one
// full-buffer read+write per layer. Fusing K consecutive layers loads each
// element once into registers, applies K butterfly layers, writes once —
// cutting full-buffer passes from log_dim to ceil(log_dim / K). Mirrors the
// CPU fused-2 / fused-4 kernels in src/ntt/additive_ntt_f128.rs.
// ---------------------------------------------------------------------------

// twiddle(layer, block) on device: XOR of layer's span basis at set bits of block.
__device__ __forceinline__ F128 evaluate_ntt_twiddle(const F128* basis, int layer, long long block) {
    F128 tw{0ull, 0ull};
    for (int j = 0; j < layer; j++)
        if ((block >> j) & 1ull) tw = f128_add(tw, basis[j]);
    return tw;
}

// One forward butterfly in a register array: nu = x[u] + x[v]*tw; x[v] += nu; x[u] = nu.
__device__ __forceinline__ void apply_ntt_butterfly(F128* x, int u, int v, F128 tw) {
    F128 nu = f128_add(x[u], ghash_mul_karatsuba(x[v], tw));
    x[v] = f128_add(x[v], nu);
    x[u] = nu;
}

// Fuse 2 layers (L, L+1). One thread per (block, r, lane); 4 elements held in
// registers. Needs block_size = 2^(log_d-L) >= 4. Matches butterfly_fused_2layer.
__global__ void additive_ntt_two_layer_tile(F128* data, const F128* bL, const F128* bL1,
                                  int L, int log_d, int num_ntts) {
    long long quarter    = 1LL << (log_d - L - 2);
    long long block_size = 1LL << (log_d - L);
    long long nblocks    = 1LL << L;
    long long total      = nblocks * quarter * (long long)num_ntts;

    long long tid = blockIdx.x * (long long)blockDim.x + threadIdx.x;
    if (tid >= total) return;
    long long lane  = tid % num_ntts;
    long long tmp   = tid / num_ntts;
    long long r     = tmp % quarter;
    long long block = tmp / quarter;

    long long stride = quarter * (long long)num_ntts;
    long long base   = block * block_size * (long long)num_ntts + r * (long long)num_ntts + lane;
    F128 x[4];
#pragma unroll
    for (int i = 0; i < 4; i++) x[i] = data[base + (long long)i * stride];

    F128 t0  = evaluate_ntt_twiddle(bL,  L,     block);
    F128 ta  = evaluate_ntt_twiddle(bL1, L + 1, 2 * block);
    F128 tb  = evaluate_ntt_twiddle(bL1, L + 1, 2 * block + 1);
    apply_ntt_butterfly(x, 0, 2, t0); apply_ntt_butterfly(x, 1, 3, t0);     // layer L:   (a,c) (b,d)
    apply_ntt_butterfly(x, 0, 1, ta); apply_ntt_butterfly(x, 2, 3, tb);     // layer L+1: (a,b) (c,d)

#pragma unroll
    for (int i = 0; i < 4; i++) data[base + (long long)i * stride] = x[i];
}

// Fuse 4 layers (L..L+3). One thread per (block, r, lane); 16 elements in
// registers. Needs block_size >= 16. Matches fused4_butterfly_scalar.
__global__ void additive_ntt_four_layer_tile(F128* data, const F128* bL, const F128* bL1,
                                  const F128* bL2, const F128* bL3,
                                  int L, int log_d, int num_ntts) {
    long long sixteenth  = 1LL << (log_d - L - 4);
    long long block_size = 1LL << (log_d - L);
    long long nblocks    = 1LL << L;
    long long total      = nblocks * sixteenth * (long long)num_ntts;

    long long tid = blockIdx.x * (long long)blockDim.x + threadIdx.x;
    if (tid >= total) return;
    long long lane  = tid % num_ntts;
    long long tmp   = tid / num_ntts;
    long long r     = tmp % sixteenth;
    long long block = tmp / sixteenth;

    long long stride = sixteenth * (long long)num_ntts;
    long long base   = block * block_size * (long long)num_ntts + r * (long long)num_ntts + lane;
    F128 x[16];
#pragma unroll
    for (int i = 0; i < 16; i++) x[i] = data[base + (long long)i * stride];

    F128 t0 = evaluate_ntt_twiddle(bL, L, block);
#pragma unroll
    for (int i = 0; i < 8; i++) apply_ntt_butterfly(x, i, i + 8, t0);                          // L  stride 8
#pragma unroll
    for (int s = 0; s < 2; s++) {
        F128 t = evaluate_ntt_twiddle(bL1, L + 1, 2 * block + s);
        for (int i = 0; i < 4; i++) apply_ntt_butterfly(x, 8 * s + i, 8 * s + i + 4, t);       // L+1 stride 4
    }
#pragma unroll
    for (int s = 0; s < 4; s++) {
        F128 t = evaluate_ntt_twiddle(bL2, L + 2, 4 * block + s);
        for (int i = 0; i < 2; i++) apply_ntt_butterfly(x, 4 * s + i, 4 * s + i + 2, t);       // L+2 stride 2
    }
#pragma unroll
    for (int s = 0; s < 8; s++) {
        F128 t = evaluate_ntt_twiddle(bL3, L + 3, 8 * block + s);
        apply_ntt_butterfly(x, 2 * s, 2 * s + 1, t);                                          // L+3 stride 1
    }

#pragma unroll
    for (int i = 0; i < 16; i++) data[base + (long long)i * stride] = x[i];
}

__device__ __forceinline__ const F128* ntt_basis_for_layer(const F128* d_tw, int layer) {
    return d_tw + ((long long)layer * (layer - 1)) / 2;
}

// Top-stage shared-memory fusion. Unlike the register-resident fusedK kernels
// (capped at K=4 by F128 register pressure — K=5 spills at 254 reg/thread), this
// holds the 2^K-position butterfly tile in SHARED memory, cooperatively across a
// block, so K can grow without per-thread register cost. The tile spans all
// `num_ntts` lanes (contiguous in the SoA layout) so global loads stay coalesced.
// Each block owns one (block, r) tile = 2^K positions x num_ntts lanes; it runs
// all K layers on-chip with a barrier between them, collapsing K full-buffer
// passes into one. smem index = pos*num_ntts + lane. Mirrors the fusedK butterfly
// schedule: layer L+j has within-tile stride 2^(K-1-j) and 2^j sub-blocks, each
// carrying twiddle evaluate_ntt_twiddle(basis_{L+j}, L+j, (block<<j)+sub).
// `lb` = lanes handled per block (a tile of the num_ntts batch dimension). At
// large num_ntts the full-lane tile (lb = num_ntts) blows the shared-mem budget
// and halves occupancy (e.g. 2^6·64·16 = 64 KB/block → ~3 blocks/SM on a 5090);
// tiling the lane dim keeps per-block smem ≈ 32 KB independent of num_ntts so
// occupancy (and thus throughput) stays high. Lanes are an independent batch
// axis — they don't affect the twiddle — so this is a pure partitioning, no math
// change. blockIdx.x enumerates (pos_tile, lane_tile): n_lane_tiles = num_ntts/lb
// inner-most. smem index = pos_in_tile*lb + lin (lin = lane within this block).
// All divisors here (lb, seg, n_lane_tiles) are powers of two but runtime
// values — written as `/` and `%` they compile to 64-bit software division,
// which runs on the (1/64-rate) FP64 pipe and was the measured top bottleneck
// (70% FP64-pipe SOL). log_lb replaces them with shifts/masks.
template <int K>
__global__ void additive_ntt_shared_memory_tile(F128* data, const F128* d_tw,
                                     int L, int log_d, int num_ntts, int log_lb,
                                     const F128* src, long long smask) {
    extern __shared__ F128 sm[];
    const int TILE       = 1 << K;
    const int NTW        = TILE - 1;          // distinct twiddles across the K layers
    const int lb         = 1 << log_lb;
    const int lbm        = lb - 1;
    int log_seg          = log_d - L - K;
    long long block_size = 1LL << (log_d - L);
    int log_nlt          = 0;                 // log2(num_ntts / lb)
    while ((lb << log_nlt) < num_ntts) log_nlt++;
    long long pos_tile   = (long long)blockIdx.x >> log_nlt;
    long long lane_tile  = (long long)blockIdx.x & ((1 << log_nlt) - 1);
    long long r          = pos_tile & ((1LL << log_seg) - 1);
    long long block      = pos_tile >> log_seg;
    long long lane_base  = lane_tile * (long long)lb;
    long long gbase      = block * block_size * (long long)num_ntts + r * (long long)num_ntts + lane_base;
    long long stride     = (long long)num_ntts << log_seg;
    long long tcount     = (long long)TILE * lb;
    F128* twid           = sm + tcount;       // NTW twiddles parked after the data tile

    // Coalesced load: smem[i*lb+lin] <- src[(gbase + i*stride + lin) & smask].
    // src/smask default to (data, -1) — identity. The rate-extend fusion passes
    // src = the pre-replication MESSAGE with smask = msg_elems-1: the codeword
    // before the NTT is cw[e] = msg[e mod msg_elems] (replicate_fill), so the
    // first pass can read the message directly (half the bytes) and the fill
    // pass disappears. Stores always go to data; src is a different buffer
    // there, and in the identity case all loads precede all stores per tile.
    for (long long e = threadIdx.x; e < tcount; e += blockDim.x) {
        long long i = e >> log_lb, lin = e & lbm;
        sm[e] = src[(gbase + i * stride + lin) & smask];
    }
    // Precompute the NTW distinct twiddles ONCE (was: evaluate_ntt_twiddle re-expanded per
    // butterfly — an O(layer) XOR loop recomputed across all strj*lb butterflies
    // that share a sub, up to ~1000x). Twiddle t encodes (j, sub) with
    // 2^j-1 <= t < 2^(j+1)-1 and sub = (t+1) - 2^j; value matches the per-layer
    // evaluate_ntt_twiddle(basis_{L+j}, L+j, (block<<j)+sub) bit-for-bit.
    for (int t = threadIdx.x; t < NTW; t += blockDim.x) {
        int j   = 31 - __clz(t + 1);          // floor(log2(t+1))
        int sub = (t + 1) - (1 << j);
        twid[t] = evaluate_ntt_twiddle(ntt_basis_for_layer(d_tw, L + j), L + j, (block << j) + sub);
    }
    __syncthreads();

    long long bpl = (long long)(TILE >> 1) * lb;         // butterflies per layer
#pragma unroll
    for (int j = 0; j < K; j++) {
        int strj  = 1 << (K - 1 - j);
        int twoff = (1 << j) - 1;                         // twid base for this layer
        for (long long q = threadIdx.x; q < bpl; q += blockDim.x) {
            long long lin  = q & lbm;
            long long bi   = q >> log_lb;              // 0..TILE/2-1
            long long sub  = bi / strj;
            long long p    = bi - sub * strj;
            long long ubase= sub * (strj << 1) + p;
            F128 tw = twid[twoff + sub];               // shared-mem read, no re-expand
            long long ui = ubase * lb + lin;
            long long vi = (ubase + strj) * lb + lin;
            F128 a = sm[ui], b = sm[vi];
            F128 nu = f128_add(a, ghash_mul_karatsuba(b, tw));
            sm[vi] = f128_add(b, nu);
            sm[ui] = nu;
        }
        __syncthreads();
    }

    for (long long e = threadIdx.x; e < tcount; e += blockDim.x) {
        long long i = e >> log_lb, lin = e & lbm;
        data[gbase + i * stride + lin] = sm[e];
    }
}

// Launch one K-layer smem-fused chunk at `layer`, lane-tiling so per-block smem
// ≈ TOPK_SMEM_CAP regardless of num_ntts (keeps occupancy high; lb=num_ntts when
// it fits). Valid whenever layer+K <= log_d (always true for chunks of a balanced
// split of [from,to) with to <= log_d).
template <int K, size_t SharedMemoryBytes = 32 * 1024>
inline void launch_ntt_shared_memory_chunk(F128* d_data, const F128* d_tw, int layer, int log_d,
                              int num_ntts, int tpb,
                              const F128* src = nullptr, long long smask = -1) {
    int lb = num_ntts, log_lb = 0;
    while ((1 << log_lb) < num_ntts) log_lb++;
    while ((size_t)(1LL << K) * (size_t)lb * sizeof(F128) > SharedMemoryBytes && lb > 1) {
        lb >>= 1; log_lb--;
    }
    size_t smem = ((size_t)(1LL << K) * (size_t)lb + ((1u << K) - 1)) * sizeof(F128);
    cudaFuncSetAttribute(additive_ntt_shared_memory_tile<K>,
                         cudaFuncAttributeMaxDynamicSharedMemorySize, (int)smem);
    long long tiles = (1LL << (log_d - K)) * (long long)(num_ntts / lb);
    additive_ntt_shared_memory_tile<K><<<(unsigned)tiles, tpb, smem>>>(d_data, d_tw, layer, log_d, num_ntts, log_lb,
                                                            src ? src : d_data, smask);
}

// Fused launches for layers [from, to). Each full-buffer pass costs one DRAM
// read+write, so we minimize PASS COUNT: split the layers into ceil(total/KMAX)
// balanced chunks (KMAX=7 — the deepest tile that still keeps smem ~32 KB at
// lb=16). Balanced (not greedy) avoids a trailing lone layer: 19 layers go
// 7+6+6 (3 passes) instead of 6+6+6+1 (4 passes). Chunks of 4/2/1 fall back to
// the register-fused / single-layer kernels (cheaper than a smem tile at small K).
template <int MaxFusedLayers = 7, size_t SharedMemoryBytes = 32 * 1024>
inline void launch_ntt_fused_layers(F128* d_data, const F128* d_tw, const TwiddleTable& tt,
                             int from, int to, int log_d, int num_ntts, int tpb,
                             const F128* src0 = nullptr, long long smask0 = -1) {
    int total = to - from;
    if (total <= 0) return;
    static_assert(MaxFusedLayers >= 1 && MaxFusedLayers <= 7);
    int npass = (total + MaxFusedLayers - 1) / MaxFusedLayers;
    int base = total / npass, extra = total % npass;
    int layer = from;
    for (int p = 0; p < npass; p++) {
        int c = base + (p < extra ? 1 : 0);     // this chunk's layer count
        // Rate-extend fusion: pass 0 may read from src0 (the pre-replication
        // message) via smask0 — shared-memory chunks only (see ntt_can_fuse_source).
        const F128* src = (p == 0) ? src0 : nullptr;
        long long smask = (p == 0) ? smask0 : -1;
        long long total_bf, blocks;
        switch (c) {
            case 7: launch_ntt_shared_memory_chunk<7, SharedMemoryBytes>(d_data, d_tw, layer, log_d, num_ntts, tpb, src, smask); break;
            case 6: launch_ntt_shared_memory_chunk<6, SharedMemoryBytes>(d_data, d_tw, layer, log_d, num_ntts, tpb, src, smask); break;
            case 5: launch_ntt_shared_memory_chunk<5, SharedMemoryBytes>(d_data, d_tw, layer, log_d, num_ntts, tpb, src, smask); break;
            case 3: launch_ntt_shared_memory_chunk<3, SharedMemoryBytes>(d_data, d_tw, layer, log_d, num_ntts, tpb, src, smask); break;
            case 4:
                total_bf = (1LL << layer) * (1LL << (log_d - layer - 4)) * (long long)num_ntts;
                blocks = (total_bf + tpb - 1) / tpb;
                additive_ntt_four_layer_tile<<<(unsigned)blocks, tpb>>>(
                    d_data, d_tw + tt.off[layer], d_tw + tt.off[layer + 1],
                    d_tw + tt.off[layer + 2], d_tw + tt.off[layer + 3], layer, log_d, num_ntts);
                break;
            case 2:
                total_bf = (1LL << layer) * (1LL << (log_d - layer - 2)) * (long long)num_ntts;
                blocks = (total_bf + tpb - 1) / tpb;
                additive_ntt_two_layer_tile<<<(unsigned)blocks, tpb>>>(
                    d_data, d_tw + tt.off[layer], d_tw + tt.off[layer + 1], layer, log_d, num_ntts);
                break;
            default:  // c == 1
                total_bf = (1LL << (log_d - 1)) * (long long)num_ntts;
                blocks = (total_bf + tpb - 1) / tpb;
                additive_ntt_layer<<<(unsigned)blocks, tpb>>>(
                    d_data, d_tw + tt.off[layer], layer, log_d, num_ntts);
                break;
        }
        layer += c;
    }
}

// Host launcher: forward interleaved NTT, layers [log_inv_rate, k_code).
// Uses balanced shared-memory chunks, then register kernels for chunks of 4/2/1.
// Caller syncs. `d_tw`/`tt` come from build_twiddle_table (uploaded to device).
// True when the first fused pass is a smem-shared-memory chunk (layer counts 3,5,6,7 of
// a balanced split — everything except totals 1/2/4, which use the register
// kernels without the src/smask load hook). Callers that want the rate-extend
// fusion (skip replicate_fill, first pass reads the message) must check this
// and fall back to replicate_fill + plain launch_ntt when false.
inline bool ntt_can_fuse_source(int total_layers) {
    return total_layers > 0 && total_layers != 1 && total_layers != 2 && total_layers != 4;
}

inline void launch_ntt(F128* d_data, const F128* d_tw, const TwiddleTable& tt,
                       int log_inv_rate, int k_code, int num_ntts,
                       int tpb = 256,
                       const F128* src0 = nullptr, long long smask0 = -1) {
    int log_d = k_code;
    int total_layers = k_code - log_inv_rate;
    if (total_layers <= 0) return;

    launch_ntt_fused_layers(d_data, d_tw, tt, log_inv_rate, k_code, log_d, num_ntts, tpb, src0, smask0);
}
