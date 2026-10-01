// BLAKE3 R1CS witness generation on GPU — byte-exact port of
// src/r1cs_hashes/blake3.rs::build_block_witness_ab_packed_into driven by
// common.rs::drive_witness_packed_and_lincheck (the S4 "GPU witness" target).
//
// Layout: the **Option F** encoding (zk.golf BLAKE3 record) — each G is two
// fused 3-operand ADDs (61 product rows each: 31 majority + 30 ripple) plus
// two 2-operand ADDs (31 carry rows), 184 bits generically; round 1's four
// column G's read c = IV[g] (a compile-time constant), which trims their
// ADD_C1 group to 30/30/29/29 rows, so G bases are a prefix sum, not a
// uniform stride. The I/O regions are 128-bit aligned:
//   words 0-1  cv       [0, 256)     words 2-3  out_lo  [256, 512)
//   words 4-7  m        [512, 1024)  word  8    params  [1024, 1152)
//   words 9-10 out_hi   [1152, 1408) G blocks   [1408, 11706)
// and the constant pin sits at the very END (bit 11,706).
//
// Per BLAKE3 block (Compression = cv[8], m[16], counter, block_len, flags):
//   - run the 7-round / 8-G trace, materializing every product row,
//   - OR the bits into the block's K/64 = 256-u64 slices of z / a / b
//     (z = witness/products, a = A-side operands, b = B-side operands;
//      linear "= word" rows put `word` in z & a and all-ones in b),
//   - then a separate kernel bit-transposes each 8-block group into the
//     lincheck stripe (K bytes per group).
//
// Pure integer ops (u32/u64) — no field math, independent of f128.cuh.
// Host-compilable for oracle validation: the serial builder and layout
// helpers build under a plain C++ compiler (the kernels and the lane-parallel
// builder are guarded behind __CUDACC__).
#pragma once
#include <cstdint>

#ifndef __CUDACC__
#define B3_DEV inline
#define B3_CONST_QUAL static const
#else
#define B3_DEV __device__ __forceinline__
#define B3_CONST_QUAL __device__ __constant__
#endif

typedef unsigned long long b3u64;

// ---- constants (verbatim from blake3.rs) ----------------------------------
#define B3_K_LOG 14
#define B3_K (1 << B3_K_LOG)            // 16384
#define B3_U64_PER_BLOCK (B3_K / 64)    // 256
#define B3_N_ROUNDS 7
#define B3_N_G_PER_ROUND 8
#define B3_N_G (B3_N_ROUNDS * B3_N_G_PER_ROUND) // 56
#define B3_WORD_BITS 32
#define B3_CARRY_BITS 31                // WORD_BITS - 1
#define B3_RIPPLE_BITS 30               // WORD_BITS - 2 (fused add layer 2)
#define B3_FADD_BITS 61                 // 31 majority + 30 ripple
#define B3_G_STRIDE 184                 // generic G: 2*61 + 2*31
#ifndef B3_TPB
#define B3_TPB 128
#endif

// layout bases (I/O-aligned Option F layout)
#define B3_CV_BASE 0
#define B3_OUT_LO_BASE 256
#define B3_M_BASE 512
#define B3_T_LO_BASE 1024
#define B3_T_HI_BASE 1056
#define B3_BLEN_BASE 1088
#define B3_FLAGS_BASE 1120
#define B3_OUT_HI_BASE 1152
#define B3_GS_BASE 1408
#define B3_Z_CONST_POS 11706            // = G_BASE[N_G]
#define B3_USEFUL_BITS 11707

// within-G bit offsets (relative to the G base)
#define B3_OFF_MAJ1 0
#define B3_OFF_RIP1 31
#define B3_OFF_C1 61
#define B3_OFF_MAJ2G 92                 // generic G (c1 = 31 rows)
#define B3_OFF_RIP2G 123
#define B3_OFF_C2G 153

// Materialized rows of G g's ADD_C1 (c + d_1): round 1's column G's read
// c = IV[g] — IV[0]/IV[1] odd → 30 rows, IV[2]/IV[3] even with bit 1 set →
// 29; every other G pays the full 31 (blake3.rs::g_c1_rows).
B3_DEV int b3_g_c1_rows(int g) { return (g < 2) ? 30 : (g < 4) ? 29 : 31; }

// First bit of G g's block: prefix sum of 183/183/182/182 then 184 each
// (blake3.rs::G_BASE). Branch-arithmetic, no local array (see B3_PERM_R note).
B3_DEV int b3_g_base(int g) {
    return (g >= 4) ? (2138 + (g - 4) * B3_G_STRIDE)
                    : (B3_GS_BASE + g * 183 - (g >= 3 ? 1 : 0));
}

B3_CONST_QUAL uint32_t B3_IV[8] = {
    0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
    0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u};

B3_CONST_QUAL int B3_G_LANES[8][4] = {
    {0, 4, 8, 12}, {1, 5, 9, 13}, {2, 6, 10, 14}, {3, 7, 11, 15},
    {0, 5, 10, 15}, {1, 6, 11, 12}, {2, 7, 8, 13}, {3, 4, 9, 14}};

B3_CONST_QUAL int B3_G_MSG_IDX[8][2] = {
    {0, 1}, {2, 3}, {4, 5}, {6, 7}, {8, 9}, {10, 11}, {12, 13}, {14, 15}};

// B3_MSG_PERM composed r times — the message schedule as used in round r.
// Precomposed so the trace builder needs no runtime perm[]/next[] arrays:
// `perm[B3_MSG_PERM[i]]` forced those (and the m[] they index) into LOCAL
// memory (ptxas: 128 B stack), and the resulting per-G local loads were 45 GB
// of L2 traffic per witness build — the kernel's measured bottleneck (L2 94%,
// DRAM 40%). PERM_R[0]=id, PERM_R[r][i]=PERM_R[r-1][MSG_PERM[i]]
// (= blake3.rs::per_round_msg_idx's composition).
B3_CONST_QUAL int B3_PERM_R[B3_N_ROUNDS][16] = {
    {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
    {2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8},
    {3, 4, 10, 12, 13, 2, 7, 14, 6, 5, 9, 0, 11, 15, 8, 1},
    {10, 7, 12, 9, 14, 3, 13, 15, 4, 0, 11, 2, 5, 8, 1, 6},
    {12, 13, 9, 11, 15, 10, 14, 8, 7, 2, 5, 3, 0, 1, 6, 4},
    {9, 14, 11, 5, 8, 12, 15, 1, 13, 3, 0, 10, 2, 6, 4, 7},
    {11, 15, 5, 0, 1, 9, 8, 6, 14, 10, 2, 12, 3, 4, 7, 13},
};

// ---- bit-packing primitives (verbatim from common.rs) ---------------------
B3_DEV void b3_or_bit_at(b3u64* buf, int bit) {
    buf[bit >> 6] |= 1ull << (bit & 63);
}
B3_DEV void b3_or_u32_at_bit(b3u64* buf, int bit, uint32_t val) {
    int idx = bit >> 6, s = bit & 63;
    buf[idx] |= (b3u64)val << s;
    if (s > 32) buf[idx + 1] |= (b3u64)val >> (64 - s);
}
B3_DEV uint32_t b3_rotr(uint32_t x, int n) {
    return (x >> n) | (x << (32 - n));
}

// add_carry_parts: sum, left=(x^cin)&0x7FFFFFFF, right=(y^cin)&…, carry=left&right.
B3_DEV uint32_t b3_add_carry(uint32_t x, uint32_t y,
                             uint32_t* left, uint32_t* right,
                             uint32_t* carry) {
    uint32_t sum = x + y;
    uint32_t cin = sum ^ x ^ y;
    uint32_t l = (x ^ cin) & 0x7FFFFFFFu;
    uint32_t r = (y ^ cin) & 0x7FFFFFFFu;
    *left = l; *right = r; *carry = l & r;
    return sum;
}

// fused_add3_parts (common.rs): x + y + m mod 2^32 as one carry-save layer +
// ripple — 61 product rows. Layer 1 (bits 0..30): majority products
// w_i = (x_i^m_i)(y_i^m_i). Layer 2 (bits 1..30, stored >>1): ripple products
// of p = x^y^m against bw = (w^m)<<1. out triples are [left, right, prod].
B3_DEV uint32_t b3_fused_add3(uint32_t x, uint32_t y, uint32_t m,
                              uint32_t maj[3], uint32_t rip[3]) {
    uint32_t xm = x ^ m, ym = y ^ m;
    uint32_t w = xm & ym;
    uint32_t p = x ^ y ^ m;
    uint32_t bw = (w ^ m) << 1;
    uint32_t sum = p + bw;
    uint32_t cin = sum ^ p ^ bw;
    uint32_t rl = p ^ cin, rr = bw ^ cin;
    maj[0] = xm & 0x7FFFFFFFu;
    maj[1] = ym & 0x7FFFFFFFu;
    maj[2] = w & 0x7FFFFFFFu;
    rip[0] = (rl >> 1) & 0x3FFFFFFFu;
    rip[1] = (rr >> 1) & 0x3FFFFFFFu;
    rip[2] = ((rl & rr) >> 1) & 0x3FFFFFFFu;
    return sum;
}

// BitRecord<3>: push a u32 at record-bit POS, flush ORs the 3-word record
// (one <=184-bit G block) into `buf` at bit `base` with spill into buf[bi+3].
B3_DEV void b3_rec_push(b3u64 rec[3], int pos, uint32_t val) {
    int idx = pos >> 6, s = pos & 63;
    rec[idx] |= (b3u64)val << s;
    if (s > 32) rec[idx + 1] |= (b3u64)val >> (64 - s);
}
B3_DEV void b3_rec_flush(const b3u64 rec[3], b3u64* buf, int base) {
    int bi = base >> 6, s = base & 63;
    b3u64 spill = 0;
#pragma unroll
    for (int j = 0; j < 3; j++) {
        buf[bi + j] |= (rec[j] << s) | spill;
        spill = (rec[j] >> 1) >> (63 - s);  // = rec[j] >> (64 - s), no UB at s=0
    }
    buf[bi + 3] |= spill;
}

// ---- one G's trace record --------------------------------------------------
// Computes G `g` on state lanes (la,lb,lc,ld) with message words (mx,my),
// pushes the `which` slice's rows (0:z = products, 1:a = left operands,
// 2:b = right operands) into rec, and updates the state. The two fused ADDs
// push [left,right,prod] triples slice-selected; the two 2-op ADDs push
// (carry|left|right); round 1's column G's mask + shift ADD_C1 down to its
// trimmed width (blake3.rs's push3! runtime path).
#define B3_SEL3(t) ((which == 0) ? (t)[2] : (which == 1) ? (t)[0] : (t)[1])
#define B3_SELC ((which == 0) ? C : (which == 1) ? L : R)
B3_DEV void b3_g_update(b3u64 rec[3], int which, int g, uint32_t* st,
                        int la, int lb, int lc, int ld,
                        uint32_t mx, uint32_t my, uint32_t iv_g) {
    uint32_t a_val = st[la], b_val = st[lb], c_val = st[lc], d_val = st[ld];
    uint32_t maj[3], rip[3];
    uint32_t L, R, C;

    uint32_t a_1 = b3_fused_add3(a_val, b_val, mx, maj, rip);
    b3_rec_push(rec, B3_OFF_MAJ1, B3_SEL3(maj));
    b3_rec_push(rec, B3_OFF_RIP1, B3_SEL3(rip));
    uint32_t d_1 = b3_rotr(d_val ^ a_1, 16);

    uint32_t c_1;
    if (g < 4) {
        // c = IV[g] is constant: the low 1-2 carries are affine — shift the
        // trimmed group down to bit 0 of its narrower slot.
        c_1 = b3_add_carry(iv_g, d_1, &L, &R, &C);
        int n = b3_g_c1_rows(g), t = B3_CARRY_BITS - n;
        uint32_t mask = (1u << n) - 1;
        b3_rec_push(rec, B3_OFF_C1, (B3_SELC >> t) & mask);
    } else {
        c_1 = b3_add_carry(c_val, d_1, &L, &R, &C);
        b3_rec_push(rec, B3_OFF_C1, B3_SELC);
    }
    uint32_t b_1 = b3_rotr(b_val ^ c_1, 12);

    uint32_t a_2 = b3_fused_add3(a_1, b_1, my, maj, rip);
    uint32_t d_2 = b3_rotr(d_1 ^ a_2, 8);
    uint32_t c_2 = b3_add_carry(c_1, d_2, &L, &R, &C);
    int maj2 = (g < 4) ? (B3_OFF_C1 + b3_g_c1_rows(g)) : B3_OFF_MAJ2G;
    b3_rec_push(rec, maj2, B3_SEL3(maj));
    b3_rec_push(rec, maj2 + B3_CARRY_BITS, B3_SEL3(rip));
    b3_rec_push(rec, maj2 + B3_FADD_BITS, B3_SELC);
    uint32_t b_new = b3_rotr(b_1 ^ c_2, 7);

    st[la] = a_2; st[lb] = b_new; st[lc] = c_2; st[ld] = d_2;
}
#undef B3_SELC

// ---- per-block trace builder ----------------------------------------------
// Builds one `which` slice (0:z, 1:a, 2:b) of one block's trace into `buf`
// (256 u64, caller-zeroed; shared or local). Linear "= word" rows put `word`
// in z & a and all-ones in b → LINVAL; the constant pin (z[0]·z[0] = z[0])
// is a 1 in all three slices.
#define LINVAL(v) ((which == 2) ? 0xFFFFFFFFu : (uint32_t)(v))
B3_DEV void b3_build_trace(b3u64* buf, int which,
                           const uint32_t cv[8], const uint32_t m[16],
                           uint32_t counter_lo, uint32_t counter_hi,
                           uint32_t block_len, uint32_t flags) {
    b3_or_bit_at(buf, B3_Z_CONST_POS);  // constant pin: 1 in all three
#pragma unroll
    for (int w = 0; w < 8; w++) b3_or_u32_at_bit(buf, B3_CV_BASE + 32 * w, LINVAL(cv[w]));
#pragma unroll
    for (int i = 0; i < 16; i++) b3_or_u32_at_bit(buf, B3_M_BASE + 32 * i, LINVAL(m[i]));
    b3_or_u32_at_bit(buf, B3_T_LO_BASE, LINVAL(counter_lo));
    b3_or_u32_at_bit(buf, B3_T_HI_BASE, LINVAL(counter_hi));
    b3_or_u32_at_bit(buf, B3_BLEN_BASE, LINVAL(block_len));
    b3_or_u32_at_bit(buf, B3_FLAGS_BASE, LINVAL(flags));

    uint32_t state[16];
#pragma unroll
    for (int w = 0; w < 8; w++) state[w] = cv[w];
#pragma unroll
    for (int w = 0; w < 8; w++) state[8 + w] = B3_IV[w];
    state[12] = counter_lo; state[13] = counter_hi;
    state[14] = block_len;  state[15] = flags;

    for (int r = 0; r < B3_N_ROUNDS; r++) {
        for (int gi = 0; gi < B3_N_G_PER_ROUND; gi++) {
            int g = r * B3_N_G_PER_ROUND + gi;
            int la = B3_G_LANES[gi][0], lb = B3_G_LANES[gi][1];
            int lc = B3_G_LANES[gi][2], ld = B3_G_LANES[gi][3];
            uint32_t mx = m[B3_PERM_R[r][B3_G_MSG_IDX[gi][0]]];
            uint32_t my = m[B3_PERM_R[r][B3_G_MSG_IDX[gi][1]]];
            b3u64 rec[3] = {0, 0, 0};
            b3_g_update(rec, which, g, state, la, lb, lc, ld, mx, my,
                        B3_IV[g < 4 ? g : 0]);
            b3_rec_flush(rec, buf, b3_g_base(g));
        }
    }

    // finalization XOR rows
#pragma unroll
    for (int w = 0; w < 8; w++) {
        uint32_t lo = state[w] ^ state[w + 8];
        uint32_t hi = state[w + 8] ^ cv[w];
        b3_or_u32_at_bit(buf, B3_OUT_LO_BASE + 32 * w, LINVAL(lo));
        b3_or_u32_at_bit(buf, B3_OUT_HI_BASE + 32 * w, LINVAL(hi));
    }
}
#undef LINVAL

// 8x8 bit-matrix transpose of a u64 (byte r = row r, bit t = col t): output
// byte t bit r = input byte r bit t (Hacker's Delight). Matches the scalar
// bit_transpose_64bytes per byte-chunk.
B3_DEV b3u64 b3_transpose8(b3u64 x) {
    b3u64 t;
    t = (x ^ (x >> 7)) & 0x00AA00AA00AA00AAull; x ^= t ^ (t << 7);
    t = (x ^ (x >> 14)) & 0x0000CCCC0000CCCCull; x ^= t ^ (t << 14);
    t = (x ^ (x >> 28)) & 0x00000000F0F0F0F0ull; x ^= t ^ (t << 28);
    return x;
}

#ifdef __CUDACC__

// ---- lane-parallel trace builder -------------------------------------------
// 12 lanes build one block's three slices concurrently: which = lane>>2 picks
// the slice (z/a/b), gsub = lane&3 picks one of the 4 independent G-functions
// per phase (BLAKE3 rounds = 4 column Gs then 4 diagonal Gs; each phase's Gs
// touch disjoint state quadruples, so they run in parallel with a warp sync
// between phases). Adjacent Gs' trace records share boundary words, so
// record flushes use shared-memory atomicOr; OR accumulation of disjoint bits
// commutes, so the result is bit-identical to the serial builder. `st` is the
// per-which shared state[16]; ALL 32 lanes must call (uniform __syncwarp),
// non-working lanes pass work=false.
__device__ __forceinline__ void b3_rec_flush_atomic(const b3u64 rec[3], b3u64* buf, int base) {
    int bi = base >> 6, s = base & 63;
    b3u64 spill = 0;
#pragma unroll
    for (int j = 0; j < 3; j++) {
        atomicOr((unsigned long long*)&buf[bi + j], (rec[j] << s) | spill);
        spill = (rec[j] >> 1) >> (63 - s);
    }
    atomicOr((unsigned long long*)&buf[bi + 3], spill);
}
// `m` MUST point to shared (or otherwise cheaply dynamically-indexable) memory:
// the message schedule indexes it with runtime values from B3_PERM_R.
__device__ void b3_build_trace_par(b3u64* buf, uint32_t* st, int which, int gsub, bool work,
                                   const uint32_t cv[8], const uint32_t* __restrict__ m,
                                   uint32_t counter_lo, uint32_t counter_hi,
                                   uint32_t block_len, uint32_t flags) {
#define LINVAL(v) ((which == 2) ? 0xFFFFFFFFu : (uint32_t)(v))
    if (work && gsub == 0) {
        b3_or_bit_at(buf, B3_Z_CONST_POS);
#pragma unroll
        for (int w = 0; w < 8; w++) b3_or_u32_at_bit(buf, B3_CV_BASE + 32 * w, LINVAL(cv[w]));
#pragma unroll
        for (int i = 0; i < 16; i++) b3_or_u32_at_bit(buf, B3_M_BASE + 32 * i, LINVAL(m[i]));
        b3_or_u32_at_bit(buf, B3_T_LO_BASE, LINVAL(counter_lo));
        b3_or_u32_at_bit(buf, B3_T_HI_BASE, LINVAL(counter_hi));
        b3_or_u32_at_bit(buf, B3_BLEN_BASE, LINVAL(block_len));
        b3_or_u32_at_bit(buf, B3_FLAGS_BASE, LINVAL(flags));
#pragma unroll
        for (int w = 0; w < 8; w++) { st[w] = cv[w]; st[8 + w] = B3_IV[w]; }
        st[12] = counter_lo; st[13] = counter_hi; st[14] = block_len; st[15] = flags;
    }
    __syncwarp();

    for (int r = 0; r < B3_N_ROUNDS; r++) {
        for (int phase = 0; phase < 2; phase++) {
            if (work) {
                int gi = phase * 4 + gsub;
                int g = r * B3_N_G_PER_ROUND + gi;
                int la = B3_G_LANES[gi][0], lb = B3_G_LANES[gi][1];
                int lc = B3_G_LANES[gi][2], ld = B3_G_LANES[gi][3];
                uint32_t mx = m[B3_PERM_R[r][B3_G_MSG_IDX[gi][0]]];
                uint32_t my = m[B3_PERM_R[r][B3_G_MSG_IDX[gi][1]]];
                b3u64 rec[3] = {0, 0, 0};
                b3_g_update(rec, which, g, st, la, lb, lc, ld, mx, my,
                            B3_IV[g < 4 ? g : 0]);
                b3_rec_flush_atomic(rec, buf, b3_g_base(g));
            }
            __syncwarp();
        }
    }

    if (work && gsub == 0) {
#pragma unroll
        for (int w = 0; w < 8; w++) {
            uint32_t lo = st[w] ^ st[w + 8];
            uint32_t hi = st[w + 8] ^ cv[w];
            b3_or_u32_at_bit(buf, B3_OUT_LO_BASE + 32 * w, LINVAL(lo));
            b3_or_u32_at_bit(buf, B3_OUT_HI_BASE + 32 * w, LINVAL(hi));
        }
    }
    __syncwarp();
#undef LINVAL
}

// ---- warp-per-block witness kernel -----------------------------------------
// One WARP per BLAKE3 block: 12 lanes build the three `which` slices into a
// SHARED 2 KB buffer (the old thread-per-block kernel built it in a per-thread
// LOCAL buffer — ~1.5 MB of hot state per SM, thrashing L1 and spilling ~9 GB
// to DRAM at m=33), then all 32 lanes copy it out warp-coalesced.
// Padding blocks (n_blocks <= blk < n_total) get the ZERO-input Compression
// trace — what the Rust generator emits for them (the const-wire pin).
#ifndef B3_WIT_WARPS
#define B3_WIT_WARPS 2
#endif
__global__ void blake3_witness_blocks(const uint32_t* __restrict__ cv_all,
                                      const uint32_t* __restrict__ m_all,
                                      const b3u64* __restrict__ ctr_all,
                                      const uint32_t* __restrict__ blen_all,
                                      const uint32_t* __restrict__ flags_all,
                                      int n_blocks, long long n_total,
                                      b3u64* __restrict__ z, b3u64* __restrict__ a,
                                      b3u64* __restrict__ b) {
    __shared__ b3u64 sbuf[B3_WIT_WARPS][3][B3_U64_PER_BLOCK + 1];   // +1: bank stagger
    __shared__ uint32_t sstate[B3_WIT_WARPS][3][16];
    __shared__ uint32_t smsg[B3_WIT_WARPS][17];    // per-warp message words (+1 stagger)
    int wid = threadIdx.x >> 5, lane = threadIdx.x & 31;
    long long blk = (long long)blockIdx.x * B3_WIT_WARPS + wid;
    if (blk >= n_total) return;                    // warp-uniform exit
    bool active = (blk < n_blocks);

    // 12 builder lanes: which = lane>>2 (slice), gsub = lane&3 (G within phase).
    bool work = lane < 12;
    int which_l = work ? (lane >> 2) : 0, gsub = lane & 3;
    uint32_t cv[8] = {0};
    b3u64 counter = 0; uint32_t block_len = 0, flags = 0;
    // Message words live in SHARED, one copy per warp: the schedule indexes them
    // with runtime values, and a per-lane register array would be demoted to
    // local memory (see B3_PERM_R comment — that cost 45 GB of L2 per build).
    if (lane < 16) smsg[wid][lane] = active ? m_all[blk * 16 + lane] : 0;
    if (active && work) {
#pragma unroll
        for (int w = 0; w < 8; w++) cv[w] = cv_all[blk * 8 + w];
        counter = ctr_all[blk];
        block_len = blen_all[blk];
        flags = flags_all[blk];
    }
    uint32_t counter_lo = (uint32_t)counter;
    uint32_t counter_hi = (uint32_t)(counter >> 32);

    for (int w2 = 0; w2 < 3; w2++)
        for (int j = lane; j < B3_U64_PER_BLOCK; j += 32) sbuf[wid][w2][j] = 0;
    __syncwarp();
    b3_build_trace_par(sbuf[wid][which_l], sstate[wid][which_l], which_l, gsub, work,
                       cv, smsg[wid], counter_lo, counter_hi, block_len, flags);
    b3u64* gout[3] = {z, a, b};
    for (int which = 0; which < 3; which++) {
        b3u64* gw = gout[which] + blk * B3_U64_PER_BLOCK;
#pragma unroll 4
        for (int j = lane; j < B3_U64_PER_BLOCK; j += 32) gw[j] = sbuf[wid][which][j];
    }
}

// ---- lincheck stripe transpose (port of transpose_8_u64s_to_64_bytes ->
// bit_transpose_64bytes). One thread per (group, word i): the 64-byte output
// row is 8 independent 8x8 bit-transposes (one per byte-chunk). ----
__global__ void blake3_lincheck_transpose(const b3u64* __restrict__ z, long long n_total,
                                          uint8_t* __restrict__ z_lincheck) {
    long long total = (n_total / 8) * (long long)B3_U64_PER_BLOCK;
    long long stride = (long long)gridDim.x * blockDim.x;   // grid-stride: cappable grid
    for (long long tid = (long long)blockIdx.x * blockDim.x + threadIdx.x; tid < total; tid += stride) {
        long long g = tid / B3_U64_PER_BLOCK;
        int i = (int)(tid - g * B3_U64_PER_BLOCK);

        b3u64 lanes[8];
#pragma unroll
        for (int lane = 0; lane < 8; lane++)
            lanes[lane] = z[(8 * g + lane) * (long long)B3_U64_PER_BLOCK + i];

        b3u64* dst = (b3u64*)(z_lincheck + g * (long long)B3_K + (long long)i * 64);
#pragma unroll
        for (int b_chunk = 0; b_chunk < 8; b_chunk++) {
            // src byte r = byte b_chunk of lanes[r].
            b3u64 src = 0;
#pragma unroll
            for (int r = 0; r < 8; r++)
                src |= ((lanes[r] >> (8 * b_chunk)) & 0xFFull) << (8 * r);
            dst[b_chunk] = b3_transpose8(src);  // LE: byte t → out[b_chunk*8 + t]
        }
    }
}

// ---- host launchers -------------------------------------------------------

inline void launch_blake3_witness_blocks(const uint32_t* cv, const uint32_t* m,
                                         const b3u64* ctr, const uint32_t* blen,
                                         const uint32_t* flags, int n_blocks,
                                         long long n_total, b3u64* z, b3u64* a, b3u64* b) {
    long long blocks = (n_total + B3_WIT_WARPS - 1) / B3_WIT_WARPS;
    blake3_witness_blocks<<<(unsigned)blocks, 32 * B3_WIT_WARPS>>>(cv, m, ctr, blen, flags,
                                                                   n_blocks, n_total, z, a, b);
}

inline void launch_blake3_lincheck_transpose(const b3u64* z, long long n_total,
                                             uint8_t* z_lincheck,
                                             cudaStream_t stream = 0, long long max_blocks = 0) {
    long long total = (n_total / 8) * (long long)B3_U64_PER_BLOCK;
    long long blocks = (total + 255) / 256;
    if (max_blocks > 0 && blocks > max_blocks) blocks = max_blocks;   // thin co-run grid
    blake3_lincheck_transpose<<<(unsigned)blocks, 256, 0, stream>>>(z, n_total, z_lincheck);
}

#endif  // __CUDACC__
