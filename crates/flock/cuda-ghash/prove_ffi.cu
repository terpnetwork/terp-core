// C-ABI GPU prover for the full R1CS Ligerito proof, linked into Rust by
// crates/flock-cuda-ffi. Reproduces crates/flock-prover/src/prover.rs::
// prove_ligerito byte-for-byte on the transcript:
//   commit -> bind_statement -> zerocheck (+s_hat_v_c) -> lincheck (+z_vec)
//   -> ring-switch batch -> ligerito recursion, capturing every proof field.
//
// Orchestration uses the optimized kernels exercised by bench_ligerito.cu.
// Protocol constants the Rust side owns (statement digest, zerocheck tables,
// ligerito config) are passed in so both sides share one source of truth.
//
// Output: flat little-endian byte stream (see FfiWriter) that the Rust test
// parses back into the typed proof structs; layout must match
// crates/flock-cuda-ffi/tests/gpu_roundtrip.rs::parse_proof.

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <map>
#include <mutex>
#include <vector>
#include "ntt_f128.cuh"
#include "merkle.cuh"
#include "merkle_open.hpp"
#include "merkle_open_device.cuh"
#include "induce_sumcheck.cuh"
#include "ntt_transpose.cuh"
#include "introduce_glue.cuh"
#include "sumcheck_ab.cuh"
#include "lincheck.cuh"
#include "blake3_witness.cuh"
#include "zerocheck_round1.cuh"
#include "zerocheck_round1_cpustyle.cuh"
#include "zerocheck_round2.cuh"
#include "zerocheck_tail.cuh"
#include "phi8_table.cuh"
#include "challenger.hpp"
#include "zc_challenger_device.cuh"
#include "pow_grind.cuh"
#include "f256.cuh"
#include "ligerito_f256.cuh"

#define CK(x) do { cudaError_t e=(x); if(e){ \
    printf("FFI CUDA error %s at %s:%d\n", cudaGetErrorString(e), __FILE__, __LINE__); \
    return 100; } } while(0)

namespace {

using std::vector;

class DeviceArena {
public:
    cudaError_t begin(size_t required) {
        if (!live_.empty()) return cudaErrorInvalidValue;
        if (required > capacity_) {
            cudaError_t err = cudaDeviceSynchronize();
            if (err != cudaSuccess) return err;
            if (base_) {
                err = cudaFree(base_);
                if (err != cudaSuccess) return err;
                base_ = nullptr;
                capacity_ = 0;
            }
            err = cudaMalloc(&base_, required);
            if (err != cudaSuccess) return err;
            capacity_ = required;
        }
        free_.clear();
        free_.emplace(0, capacity_);
        active_ = true;
        return cudaSuccess;
    }

    cudaError_t allocate(void** ptr, size_t bytes) {
        if (!active_ || bytes == 0) return cudaErrorInvalidValue;
        constexpr size_t alignment = 256;
        size_t aligned = (bytes + alignment - 1) & ~(alignment - 1);
        for (auto block = free_.begin(); block != free_.end(); block++) {
            if (block->second < aligned) continue;
            size_t offset = block->first;
            size_t remaining = block->second - aligned;
            free_.erase(block);
            if (remaining) free_.emplace(offset + aligned, remaining);
            *ptr = base_ + offset;
            live_.emplace(*ptr, Block{offset, aligned});
            return cudaSuccess;
        }
        return cudaErrorMemoryAllocation;
    }

    cudaError_t release(void* ptr) {
        auto live = live_.find(ptr);
        if (live == live_.end()) return cudaErrorInvalidDevicePointer;
        size_t offset = live->second.offset;
        size_t bytes = live->second.bytes;
        live_.erase(live);

        auto next = free_.lower_bound(offset);
        if (next != free_.begin()) {
            auto previous = std::prev(next);
            if (previous->first + previous->second == offset) {
                offset = previous->first;
                bytes += previous->second;
                free_.erase(previous);
            }
        }
        next = free_.lower_bound(offset);
        if (next != free_.end() && offset + bytes == next->first) {
            bytes += next->second;
            free_.erase(next);
        }
        free_.emplace(offset, bytes);
        return cudaSuccess;
    }

    cudaError_t finish() {
        active_ = false;
        return live_.empty() ? cudaSuccess : cudaErrorInvalidValue;
    }

private:
    struct Block { size_t offset, bytes; };
    uint8_t* base_ = nullptr;
    size_t capacity_ = 0;
    bool active_ = false;
    std::map<size_t, size_t> free_;
    std::map<void*, Block> live_;
};

static DeviceArena device_arena;

template <class T>
cudaError_t ffi_malloc(T** ptr, size_t bytes) {
    return device_arena.allocate((void**)ptr, bytes);
}

cudaError_t ffi_free(void* ptr) { return device_arena.release(ptr); }

struct CachedTwiddles {
    TwiddleTable host;
    F128* device;
};

cudaError_t get_cached_twiddles(int k_code, const TwiddleTable*& host, F128*& device) {
    static std::map<int, CachedTwiddles> cache;
    auto found = cache.find(k_code);
    if (found == cache.end()) {
        CachedTwiddles value{build_twiddle_table(k_code), nullptr};
        cudaError_t err = cudaMalloc(&value.device, value.host.data.size() * sizeof(F128));
        if (err != cudaSuccess) return err;
        err = cudaMemcpy(value.device, value.host.data.data(),
                         value.host.data.size() * sizeof(F128), cudaMemcpyHostToDevice);
        if (err != cudaSuccess) {
            cudaFree(value.device);
            return err;
        }
        found = cache.emplace(k_code, std::move(value)).first;
    }
    host = &found->second.host;
    device = found->second.device;
    return cudaSuccess;
}

F128 ADD(F128 a, F128 b) { return f128_add_hd(a, b); }
F128 MUL(F128 a, F128 b) { return f128_mul_hd(a, b); }
const F128 ONE{1, 0};
ChF128 toch(F128 x) { return ChF128{x.lo, x.hi}; }
F128 frch(ChF128 x) { return F128{x.lo, x.hi}; }

F128 interp3(F128 h0, F128 h1, F128 hinf, F128 rho) {
    F128 c1 = ADD(ADD(h0, h1), hinf);
    return ADD(h0, MUL(rho, ADD(c1, MUL(rho, hinf))));
}

vector<F128> build_eq_host(const F128* r, int n) {
    vector<F128> t; t.reserve((size_t)1 << n); t.push_back(ONE);
    for (int j = 0; j < n; j++) {
        F128 rj = r[j], omr = ADD(ONE, rj);
        size_t len = (size_t)1 << j; t.resize(2 * len);
        for (size_t x = 0; x < len; x++) { F128 v = t[x]; t[x + len] = MUL(v, rj); t[x] = MUL(v, omr); }
    }
    return t;
}

// Lagrange weights at z over 2^k nodes of the PHI domain (off=0: S, off=64: Λ).
vector<F128> lagrange_phi(int k, F128 z, int off) {
    const int ell = 1 << k;
    vector<F128> terms(ell), prefixes(ell), weights(ell);
    for (int i = 0; i < ell; i++) terms[i] = ADD(z, PHI_8_TABLE[off + i]);
    prefixes[0] = ONE;
    for (int i = 1; i < ell; i++) prefixes[i] = MUL(prefixes[i - 1], terms[i - 1]);

    static std::map<std::pair<int, int>, F128> denominator_inverses;
    const std::pair<int, int> domain{off, k};
    auto found = denominator_inverses.find(domain);
    if (found == denominator_inverses.end()) {
        F128 denominator = ONE;
        F128 first = PHI_8_TABLE[off];
        for (int j = 1; j < ell; j++)
            denominator = MUL(denominator, ADD(first, PHI_8_TABLE[off + j]));
        found = denominator_inverses.emplace(domain, f128_inv_host(denominator)).first;
    }

    F128 suffix = ONE;
    for (int i = ell - 1; i >= 0; i--) {
        weights[i] = MUL(MUL(prefixes[i], suffix), found->second);
        suffix = MUL(suffix, terms[i]);
    }
    return weights;
}

// ---- flat output writer (all integers u64 LE, F128 = lo,hi LE) ----
struct FfiWriter {
    vector<uint8_t> buf;
    void u64(uint64_t v) { for (int i = 0; i < 8; i++) buf.push_back((uint8_t)(v >> (8 * i))); }
    void f128(F128 v) { u64(v.lo); u64(v.hi); }
    void f128s(const vector<F128>& v) { u64(v.size()); for (auto& x : v) f128(x); }
    void hash(const uint8_t* h) { buf.insert(buf.end(), h, h + 32); }
    void hashes(const vector<MHash>& v) { u64(v.size()); for (auto& h : v) hash(h.b); }
    void rows(const vector<F128>& flat, size_t n_rows, size_t row_len) {
        u64(n_rows); u64(row_len);
        for (size_t i = 0; i < n_rows * row_len; i++) f128(flat[i]);
    }
};

// tensor-algebra transpose: out[i].bit[j] = in[j].bit[i] (128x128 bit matrix).
vector<F128> ta_transpose_host(const vector<F128>& in) {
    vector<F128> out(128, F128{0, 0});
    for (int j = 0; j < 128; j++) {
        for (int half = 0; half < 2; half++) {
            u64 bits = half ? in[j].hi : in[j].lo;
            while (bits) {
                int i = 64 * half + __builtin_ctzll(bits);
                if (j < 64) out[i].lo |= (u64)1 << j; else out[i].hi |= (u64)1 << (j - 64);
                bits &= bits - 1;
            }
        }
    }
    return out;
}

// Bench-style deterministic pseudo-random compression inputs (copy of
// bench_ligerito.cu::fill_compressions — every slot is a REAL compression, so
// the witness satisfies the R1CS and the const-pin column is 1 everywhere).
__global__ void generate_blake3_compression_inputs(uint32_t* cv, uint32_t* m, b3u64* ctr, uint32_t* blen,
                                      uint32_t* flags, int n_blocks) {
    int blk = blockIdx.x * blockDim.x + threadIdx.x;
    if (blk >= n_blocks) return;
    b3u64 s = (b3u64)blk * 0x9E3779B97F4A7C15ull + 1;
#define NXT (s = s * 6364136223846793005ull + 1, (uint32_t)(s >> 33))
    for (int w = 0; w < 8; w++) cv[blk * 8 + w] = NXT;
    for (int i = 0; i < 16; i++) m[blk * 16 + i] = NXT;
    ctr[blk] = ((b3u64)NXT << 32) | NXT; blen[blk] = NXT; flags[blk] = NXT;
#undef NXT
}

__global__ void ring_switch_fold_rows_grouped(const F128* __restrict__ witness,
                                              const F128* __restrict__ suffix, long long len,
                                              int chunks, F128* __restrict__ partials) {
    int bit_base = blockIdx.y * 8;
    F128 acc[8]{};
    for (long long i = (long long)blockIdx.x * blockDim.x + threadIdx.x;
         i < len; i += (long long)chunks * blockDim.x) {
        F128 row = witness[i];
        u64 word = bit_base < 64 ? row.lo : row.hi;
        word >>= bit_base & 63;
#pragma unroll
        for (int j = 0; j < 8; j++) {
            if ((word >> j) & 1) {
                acc[j].lo ^= suffix[i].lo;
                acc[j].hi ^= suffix[i].hi;
            }
        }
    }
    __shared__ F128 partial[256];
#pragma unroll
    for (int j = 0; j < 8; j++) {
        partial[threadIdx.x] = acc[j];
        __syncthreads();
        for (int stride = blockDim.x / 2; stride; stride >>= 1) {
            if (threadIdx.x < stride) {
                partial[threadIdx.x].lo ^= partial[threadIdx.x + stride].lo;
                partial[threadIdx.x].hi ^= partial[threadIdx.x + stride].hi;
            }
            __syncthreads();
        }
        if (threadIdx.x == 0)
            partials[((long long)(bit_base + j) * chunks) + blockIdx.x] = partial[0];
        __syncthreads();
    }
}

__global__ void ring_switch_fold_rows_reduce(const F128* __restrict__ partials,
                                             int chunks, F128* __restrict__ shat) {
    int bit = blockIdx.x;
    F128 acc{0, 0};
    for (int i = threadIdx.x; i < chunks; i += blockDim.x) {
        acc.lo ^= partials[(long long)bit * chunks + i].lo;
        acc.hi ^= partials[(long long)bit * chunks + i].hi;
    }
    __shared__ F128 shared[256];
    shared[threadIdx.x] = acc;
    __syncthreads();
    for (int stride = blockDim.x / 2; stride; stride >>= 1) {
        if (threadIdx.x < stride) {
            shared[threadIdx.x].lo ^= shared[threadIdx.x + stride].lo;
            shared[threadIdx.x].hi ^= shared[threadIdx.x + stride].hi;
        }
        __syncthreads();
    }
    if (threadIdx.x == 0) shat[bit] = shared[0];
}

__global__ void ring_switch_fold_witness_evaluations(const F128* __restrict__ zvec,
                                      const F128* __restrict__ eq_tail,
                                      int tail_len, F128* __restrict__ shat) {
    int bit = blockIdx.x;
    F128 acc{0, 0};
    for (int k = threadIdx.x; k < tail_len; k += blockDim.x)
        acc = f128_add(acc, ghash_mul_karatsuba(eq_tail[k], zvec[(long long)k * 128 + bit]));
    __shared__ F128 partial[128];
    partial[threadIdx.x] = acc;
    __syncthreads();
    for (int stride = blockDim.x / 2; stride; stride >>= 1) {
        if (threadIdx.x < stride)
            partial[threadIdx.x] = f128_add(partial[threadIdx.x], partial[threadIdx.x + stride]);
        __syncthreads();
    }
    if (threadIdx.x == 0) shat[bit] = partial[0];
}

__global__ void ring_switch_combine_basis(const F128* __restrict__ suffix_ab,
                                          const F128* __restrict__ suffix_c,
                                          const F128* __restrict__ weights_ab,
                                          const F128* __restrict__ weights_c,
                                          long long len, F128* __restrict__ combined) {
    long long i = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= len) return;
    F128 acc{0, 0};
    const F128 suffixes[2] = {suffix_ab[i], suffix_c[i]};
    const F128* weights[2] = {weights_ab, weights_c};
    for (int claim = 0; claim < 2; claim++) {
        for (int half = 0; half < 2; half++) {
            u64 bits = half ? suffixes[claim].hi : suffixes[claim].lo;
            while (bits) {
                int bit = __ffsll((long long)bits) - 1;
                F128 w = weights[claim][64 * half + bit];
                acc.lo ^= w.lo;
                acc.hi ^= w.hi;
                bits &= bits - 1;
            }
        }
    }
    combined[i] = acc;
}

cudaError_t lig_arena_alloc(void** p, size_t bytes) { return device_arena.allocate(p, bytes); }
cudaError_t lig_arena_release(void* p) { return device_arena.release(p); }

} // namespace

// ---- C ABI ----
extern "C" {

typedef struct {
    // instance
    int m;                        // = 14 + n_blocks_log
    const uint8_t* statement_digest;   // 32 bytes (BLAKE3, computed Rust-side)
    const uint8_t* domain;             // challenger domain
    uint32_t domain_len;
    // lincheck CSC matrices (K = 2^14 columns)
    const uint32_t* a_col_ptr; const uint32_t* a_rows; uint32_t a_nnz;
    const uint32_t* b_col_ptr; const uint32_t* b_rows; uint32_t b_nnz;
    int const_pin_col;            // -1 = none; BLAKE3: 512
    int useful_bits;              // 15409
    int k_log;                    // 14
    // zerocheck round-1 tables (protocol constants, Rust-side source of truth)
    const uint8_t* zc_mcol;       // 64*64
    const uint8_t* zc_f8mul;      // 256*256
    // ligerito config (embedded TOML on the Rust side)
    int initial_k;                // 6
    int num_levels;               // = recursive_steps + 1
    const int* log_inv_rates;     // [num_levels]
    const int* recursive_ks;      // [recursive_steps]
    const int* queries;           // [num_levels]
    const int* grinding_bits;     // [num_levels] query-phase PoW
    const int* claim_batch_grinding_bits;       // [num_levels]
    const int* consistency_batch_grinding_bits; // [num_levels]
    const int* ood_samples;       // [num_levels]
    int recursive_steps;
    // 128-bit FS grinding schedule for the PIOPs + transport (from the Rust
    // PcsParams accessors). 0 = the site is ABSENT (no PoW op, legacy shape);
    // the ligerito claim/consistency/query grinds above always absorb, 0-bit
    // included.
    int zc_initial_bits;          // ZerocheckGrinding::initial_bits(m)
    int zc_skip_bits;             // ZerocheckGrinding::skip_bits()
    int zc_round_bits;            // ZerocheckGrinding::multilinear_round_bits()
    int lc_alpha_bits;            // LincheckGrinding::alpha_bits()
    int lc_beta_bits;             // LincheckGrinding::beta_bits() (per pinned circuit)
    int lc_round_bits;            // LincheckGrinding::multilinear_round_bits()
    int lc_skip_bits;             // LincheckGrinding::skip_bits(k_skip)
    int rs_bits;                  // OpeningGrinding::ring_switch_bits (per claim)
    int gamma_bits;               // OpeningGrinding::claim_batch_bits (2 claims)
    // Optional: dump the generated packed witness (len F128, raw LE) here so a
    // host-side Rust prover can replay the identical instance. NULL = no dump.
    const char* dump_z_path;
} FlockCudaProveParams;

int flock_cuda_device_count() {
    int n = 0;
    cudaError_t e = cudaGetDeviceCount(&n);
    if (e != cudaSuccess) return -(int)e;
    return n;
}

void flock_cuda_free(uint8_t* p) { free(p); }

// Returns 0 on success; out/out_len receive a malloc'd flat proof stream.
int flock_cuda_prove_blake3(const FlockCudaProveParams* P, uint8_t** out, size_t* out_len) {
    static std::mutex prover_mutex;
    std::lock_guard<std::mutex> prover_lock(prover_mutex);
    const int m = P->m, k_log = P->k_log, k_skip = 6;
    const int log_n = m - 7;                    // packed-witness log length
    const long long len = 1LL << log_n;         // packed F128 elements
    const int n_blocks_log = m - 14;
    const long long n_total = 1LL << n_blocks_log;
    const int n_blocks = (int)n_total;
    if (n_blocks_log < 3) { printf("FFI: m too small\n"); return 101; }
    const size_t packed_witness_bytes = (size_t)len * sizeof(F128);
    // The measured m=34 peak is 14.149 packed-witness buffers. This capacity
    // adds space for fixed-size scratch while leaving VRAM for persistent data.
    const size_t arena_bytes = packed_witness_bytes / 2 * 29 + (64ull << 20);
    CK(device_arena.begin(arena_bytes));
    // ================= witness (real BLAKE3 compressions, deterministic) ====
    F128 *df, *d_a, *d_b; uint8_t* d_zlin;
    CK(ffi_malloc(&df, len * sizeof(F128)));
    CK(ffi_malloc(&d_a, len * sizeof(F128)));
    CK(ffi_malloc(&d_b, len * sizeof(F128)));
    CK(ffi_malloc(&d_zlin, (size_t)len * 16));
    {
        uint32_t *d_cv, *d_m, *d_blen, *d_flags; b3u64* d_ctr;
        CK(ffi_malloc(&d_cv, (size_t)n_blocks * 8 * 4)); CK(ffi_malloc(&d_m, (size_t)n_blocks * 16 * 4));
        CK(ffi_malloc(&d_blen, (size_t)n_blocks * 4)); CK(ffi_malloc(&d_flags, (size_t)n_blocks * 4));
        CK(ffi_malloc(&d_ctr, (size_t)n_blocks * 8));
        generate_blake3_compression_inputs<<<(unsigned)((n_blocks + 127) / 128), 128>>>(d_cv, d_m, d_ctr, d_blen, d_flags, n_blocks);
        CK(cudaGetLastError());
        launch_blake3_witness_blocks(d_cv, d_m, d_ctr, d_blen, d_flags, n_blocks, n_total,
                                     (b3u64*)df, (b3u64*)d_a, (b3u64*)d_b);
        launch_blake3_lincheck_transpose((const b3u64*)df, n_total, d_zlin);
        CK(cudaDeviceSynchronize());
        ffi_free(d_cv); ffi_free(d_m); ffi_free(d_blen); ffi_free(d_flags); ffi_free(d_ctr);
    }
    if (P->dump_z_path && P->dump_z_path[0]) {
        vector<F128> z_host(len);
        CK(cudaMemcpy(z_host.data(), df, len * sizeof(F128), cudaMemcpyDeviceToHost));
        FILE* zf = fopen(P->dump_z_path, "wb");
        if (!zf) { printf("FFI: cannot open dump path %s\n", P->dump_z_path); return 103; }
        fwrite(z_host.data(), sizeof(F128), z_host.size(), zf);
        fclose(zf);
    }

    // ================= L0 commit ============================================
    F128* d_cw0; uint8_t* d_tree0; long long l0_bl; int l0_ni;
    std::vector<MHash> l0_cap;
    {
        int k_code = (log_n - P->initial_k) + P->log_inv_rates[0];
        int num_ntts = 1 << P->initial_k;
        l0_bl = 1LL << k_code; l0_ni = num_ntts;
        long long cw_len = l0_bl * num_ntts;
        const TwiddleTable* tt;
        F128* d_tw;
        CK(get_cached_twiddles(k_code, tt, d_tw));
        CK(ffi_malloc(&d_cw0, cw_len * sizeof(F128)));
        CK(ffi_malloc(&d_tree0, (size_t)(2 * l0_bl - 1) * 32));
        if (ntt_can_fuse_source(k_code - P->log_inv_rates[0])) {
            launch_ntt(d_cw0, d_tw, *tt, P->log_inv_rates[0], k_code, num_ntts, 256, df, len - 1);
        } else {
            printf("FFI: unfused L0 rate-extend not wired\n"); return 102;
        }
        CK(cudaGetLastError());
        launch_merkle((const uint8_t*)d_cw0, d_tree0, l0_bl, num_ntts * 16);
        CK(cudaDeviceSynchronize());
        // The commitment IS the cap layer (no root): 2^c nodes at the
        // stratified schedule's cap depth for the L0 query count.
        uint32_t c0 = stratified_cap_depth(
            stratified_depths((size_t)P->queries[0], (uint32_t)k_code));
        l0_cap = merkle_cap_layer_device(d_tree0, (size_t)l0_bl, c0);
    }

    // ================= challenger + statement binding =======================
    FsChallenger ch(P->domain, P->domain_len);
    ch.observe_label((const uint8_t*)"flock-r1cs-v0", 13);
    ch.observe_bytes(P->statement_digest, 32);
    ch.observe_bytes((const uint8_t*)l0_cap.data(), l0_cap.size() * 32);

    FfiWriter W;
    W.hashes(l0_cap);                     // the commitment cap

    // ================= zerocheck (test_zerocheck_full flow) =================
    vector<F128> zc_r1ab(64), zc_r1c(64), zc_m1s, zc_mis;
    F128 zc_z, zc_fa, zc_fb, zc_fc;
    vector<F128> zc_r(m), mlv_rhos;
    vector<uint64_t> zc_nonces;   // [initial, skip z, one per multilinear round]
    {
        const long long n_out = 1LL << (m - 6);
        static std::once_flag zerocheck_setup_once;
        static cudaError_t zerocheck_setup_error = cudaSuccess;
        static vector<uint8_t> setup_zc_mcol, setup_zc_f8mul;
        std::call_once(zerocheck_setup_once, [&] {
            setup_zc_mcol.assign(P->zc_mcol, P->zc_mcol + 64 * 64);
            setup_zc_f8mul.assign(P->zc_f8mul, P->zc_f8mul + 256 * 256);
            zerocheck_setup_error = upload_zerocheck_first_round_tables(P->zc_mcol, P->zc_f8mul, PHI_8_TABLE);
        });
        CK(zerocheck_setup_error);
        if (memcmp(P->zc_mcol, setup_zc_mcol.data(), setup_zc_mcol.size()) != 0 ||
            memcmp(P->zc_f8mul, setup_zc_f8mul.data(), setup_zc_f8mul.size()) != 0) {
            printf("FFI: zerocheck tables changed after setup\n");
            return 105;
        }
        F128 *d_eq, *d_r1ab, *d_r1c, *d_ft, *d_am, *d_bm, *d_amn, *d_bmn, *d_p1, *d_pinf, *d_m1d, *d_mid;
        CK(ffi_malloc(&d_eq, (1LL << (m - 13)) * sizeof(F128)));
        CK(ffi_malloc(&d_r1ab, 64 * sizeof(F128))); CK(ffi_malloc(&d_r1c, 64 * sizeof(F128)));
        CK(ffi_malloc(&d_ft, 8 * 256 * sizeof(F128)));
        CK(ffi_malloc(&d_am, n_out * sizeof(F128))); CK(ffi_malloc(&d_bm, n_out * sizeof(F128)));
        CK(ffi_malloc(&d_amn, n_out * sizeof(F128))); CK(ffi_malloc(&d_bmn, n_out * sizeof(F128)));
        CK(ffi_malloc(&d_p1, ZT_MAX_BLOCKS * sizeof(F128))); CK(ffi_malloc(&d_pinf, ZT_MAX_BLOCKS * sizeof(F128)));
        CK(ffi_malloc(&d_m1d, sizeof(F128))); CK(ffi_malloc(&d_mid, sizeof(F128)));
        const int zt_dfull = m - 7, zt_lobits = zt_dfull > 7 ? zt_dfull - 7 : 0;
        F128 *d_eqlo, *d_eqhi;
        CK(ffi_malloc(&d_eqlo, (1LL << zt_lobits) * sizeof(F128)));
        CK(ffi_malloc(&d_eqhi, (1LL << (zt_dfull - zt_lobits)) * sizeof(F128)));

        ch.observe_label((const uint8_t*)"flock-zerocheck-v0", 18);
        // PoW before the initial eq point (the skip vector); r_outer is plain.
        std::vector<ChF128> rs(6);
        if (P->zc_initial_bits > 0)
            zc_nonces.push_back(ch.grind_pow_and_sample_f128_vec((uint32_t)P->zc_initial_bits, rs.data(), 6));
        else
            ch.sample_f128_vec(rs.data(), 6);
        std::vector<ChF128> ro(m - 13); ch.sample_f128_vec(ro.data(), m - 13);
        for (int i = 0; i < 6; i++) zc_r[i] = frch(rs[i]);
        int sm[3] = {0xF7, 0x53, 0xB5};
        for (int i = 0; i < 3; i++) zc_r[6 + i] = PHI_8_TABLE[sm[i]];
        F128 gm[4] = {F128{2, 0}, F128{4, 0}, F128{16, 0}, F128{256, 0}};
        for (int i = 0; i < 4; i++) zc_r[9 + i] = MUL(gm[i], f128_inv_host(ADD(ONE, gm[i])));
        for (int i = 0; i < m - 13; i++) zc_r[13 + i] = frch(ro[i]);

        // Round one needs only eq(r[13..]). The fixed rounds contribute one scale.
        build_eq_device(d_eq, &zc_r[13], m - 13);
        F128 round1_scale = ONE;
        for (int i = 6; i < 13; i++) round1_scale = MUL(round1_scale, ADD(ONE, zc_r[i]));
        launch_zerocheck_first_round_cpu_structured((const uint8_t*)d_a, (const uint8_t*)d_b,
                                   (const uint8_t*)df, d_eq, 1LL << (m - 13),
                                   round1_scale, d_r1ab, d_r1c);
        CK(cudaGetLastError()); CK(cudaDeviceSynchronize());
        CK(cudaMemcpy(zc_r1ab.data(), d_r1ab, 64 * sizeof(F128), cudaMemcpyDeviceToHost));
        CK(cudaMemcpy(zc_r1c.data(), d_r1c, 64 * sizeof(F128), cudaMemcpyDeviceToHost));
        { std::vector<ChF128> s(64);
          for (int i = 0; i < 64; i++) s[i] = toch(zc_r1ab[i]); ch.observe_f128_slice(s.data(), 64);
          for (int i = 0; i < 64; i++) s[i] = toch(zc_r1c[i]);  ch.observe_f128_slice(s.data(), 64); }
        if (P->zc_skip_bits > 0) {
            ChF128 zc_;
            zc_nonces.push_back(ch.grind_pow_and_sample_f128((uint32_t)P->zc_skip_bits, &zc_));
            zc_z = frch(zc_);
        } else {
            zc_z = frch(ch.sample_f128());
        }

        // c-interp at z over Λ (final_c_eval)
        { vector<F128> wl = lagrange_phi(6, zc_z, 64);
          zc_fc = F128{0, 0};
          for (int i = 0; i < 64; i++) zc_fc = ADD(zc_fc, MUL(wl[i], zc_r1c[i])); }

        // Round two folds at z and returns the first two multilinear messages.
        { vector<F128> ws = lagrange_phi(6, zc_z, 0);
          vector<F128> ft(8 * 256, F128{0, 0});
          for (int j = 0; j < 8; j++) for (int v = 0; v < 256; v++) { F128 acc{0, 0};
              for (int bb = 0; bb < 8; bb++) if ((v >> bb) & 1) acc = ADD(acc, ws[8 * j + bb]);
              ft[j * 256 + v] = acc; }
          CK(cudaMemcpy(d_ft, ft.data(), 8 * 256 * sizeof(F128), cudaMemcpyHostToDevice)); }
        build_eq_device(d_eqlo, &zc_r[7], zt_lobits);
        build_eq_device(d_eqhi, &zc_r[7 + zt_lobits], zt_dfull - zt_lobits);
        F128 *cA = d_am, *cB = d_bm, *nA = d_amn, *nB = d_bmn;
        long long L = n_out;
        int n_tail = (m - 6) - 1;
        vector<F128> S(n_tail);
        { vector<F128> values(n_tail), prefixes(n_tail); F128 acc = ONE;
          for (int i = 0; i < n_tail; i++) values[i] = ADD(ONE, zc_r[7 + i]);
          for (int i = 0; i < n_tail; i++) { prefixes[i] = acc; acc = MUL(acc, values[i]); }
          F128 inv = f128_inv_host(acc);
          for (int i = n_tail - 1; i >= 0; i--) { S[i] = MUL(prefixes[i], inv); inv = MUL(inv, values[i]); }
          for (int i = 1; i < n_tail; i++) S[i] = MUL(S[i - 1], S[i]); }

        F128 *d_part8, *d_out8;
        CK(ffi_malloc(&d_part8, 8 * ZT_MAX_BLOCKS * sizeof(F128)));
        CK(ffi_malloc(&d_out8, 8 * sizeof(F128)));

        launch_zerocheck_second_round_fold_with_lookahead((const uint8_t*)d_a, (const uint8_t*)d_b, d_ft,
                                   d_eqlo, d_eqhi, zt_lobits, n_out, d_am, d_bm,
                                   S[0], d_part8, d_out8);
        CK(cudaGetLastError());

        auto observe_message = [&](F128 m1, F128 mi) {
            zc_m1s.push_back(m1); zc_mis.push_back(mi);
            ch.observe_f128(toch(m1)); ch.observe_f128(toch(mi));
            if (P->zc_round_bits > 0) {
                ChF128 rho;
                zc_nonces.push_back(ch.grind_pow_and_sample_f128((uint32_t)P->zc_round_bits, &rho));
                mlv_rhos.push_back(frch(rho));
            } else {
                mlv_rhos.push_back(frch(ch.sample_f128()));
            }
        };
        F128 h[8];
        CK(cudaMemcpy(h, d_out8, 8 * sizeof(F128), cudaMemcpyDeviceToHost));
        observe_message(h[0], h[1]);
        F128 rho0 = mlv_rhos.back();
        observe_message(interp3(h[2], h[3], h[4], rho0),
                        interp3(h[5], h[6], h[7], rho0));

        int k = 2;
        while (k + 1 <= n_tail && L / 16 > ZT_FINISH_OP) {
            launch_zerocheck_tail_lookahead(cA, cB, nA, nB, d_eqlo, d_eqhi, k, zt_lobits, L / 16,
                                mlv_rhos[mlv_rhos.size() - 2], mlv_rhos.back(),
                                S[k - 1], S[k], d_part8, d_out8);
            CK(cudaGetLastError());
            { F128* t; t = cA; cA = nA; nA = t; t = cB; cB = nB; nB = t; }
            L /= 4;
            CK(cudaMemcpy(h, d_out8, 8 * sizeof(F128), cudaMemcpyDeviceToHost));
            observe_message(h[0], h[1]);
            F128 rho = mlv_rhos.back();
            observe_message(interp3(h[2], h[3], h[4], rho),
                            interp3(h[5], h[6], h[7], rho));
            k += 2;
        }

        // One pending challenge aligns the remaining single-round or finisher path.
        { long long half = L / 2;
          launch_sumcheck_fold(cA, cB, nA, nB, half, mlv_rhos[mlv_rhos.size() - 2]);
          CK(cudaGetLastError());
          F128* t; t = cA; cA = nA; nA = t; t = cB; cB = nB; nB = t;
          L = half; }
        // Host-driven rounds to the end. The device finisher
        // (finish_zerocheck_tail) predates per-round PoW grinding — every
        // round's ρ is now ground on the host challenger, so the last rounds
        // run as (tiny) individual kernels instead. ~n_tail extra launches,
        // microseconds total.
        int i = k - 1;
        for (; i < n_tail; i++) {
            launch_zerocheck_tail_fold_and_message(cA, cB, nA, nB, d_eqlo, d_eqhi, i + 1, zt_lobits,
                                     L / 4, mlv_rhos.back(), S[i],
                                     d_p1, d_pinf, d_m1d, d_mid);
            CK(cudaGetLastError());
            { F128* t; t = cA; cA = nA; nA = t; t = cB; cB = nB; nB = t; }
            L /= 2;
            F128 m1, mi;
            CK(cudaMemcpy(&m1, d_m1d, sizeof(F128), cudaMemcpyDeviceToHost));
            CK(cudaMemcpy(&mi, d_mid, sizeof(F128), cudaMemcpyDeviceToHost));
            observe_message(m1, mi);
        }

        // final binding + evals
        { long long half = L / 2; launch_sumcheck_fold(cA, cB, nA, nB, half, mlv_rhos.back());
          CK(cudaGetLastError()); CK(cudaDeviceSynchronize());
          F128* t; t = cA; cA = nA; nA = t; t = cB; cB = nB; nB = t; }
        CK(cudaMemcpy(&zc_fa, cA, sizeof(F128), cudaMemcpyDeviceToHost));
        CK(cudaMemcpy(&zc_fb, cB, sizeof(F128), cudaMemcpyDeviceToHost));
        ch.observe_f128(toch(zc_fa)); ch.observe_f128(toch(zc_fb));

        ffi_free(d_eq); ffi_free(d_r1ab); ffi_free(d_r1c); ffi_free(d_ft);
        ffi_free(d_am); ffi_free(d_bm); ffi_free(d_amn); ffi_free(d_bmn);
        ffi_free(d_p1); ffi_free(d_pinf); ffi_free(d_m1d); ffi_free(d_mid);
        ffi_free(d_eqlo); ffi_free(d_eqhi);
        ffi_free(d_part8); ffi_free(d_out8);
    }
    ffi_free(d_a); ffi_free(d_b);
    // zerocheck proof section
    W.f128s(zc_r1ab); W.f128s(zc_r1c);
    W.u64(zc_m1s.size());
    for (size_t i = 0; i < zc_m1s.size(); i++) { W.f128(zc_m1s[i]); W.f128(zc_mis[i]); }
    W.f128(zc_fa); W.f128(zc_fb); W.f128(zc_fc);
    W.u64(zc_nonces.size());
    for (uint64_t n : zc_nonces) W.u64(n);

    // x_ab (RowMajor): z_skip = zc_z, inner = mlv[..k_log-6], outer = mlv[k_log-6..]
    const int irl = k_log - k_skip;
    vector<F128> xab_inner(mlv_rhos.begin(), mlv_rhos.begin() + irl);
    vector<F128> xab_outer(mlv_rhos.begin() + irl, mlv_rhos.end());

    // ================= lincheck (test_lincheck flow + const-pin beta) =======
    vector<F128> lc_e1s, lc_einfs, lc_zpart(64), lc_rrounds;
    vector<uint64_t> lc_nonces;   // [α, β per pin, one per round, φ8 skip]
    F128 lc_rskip, lc_w;
    F128* d_zvec = nullptr;
    F128* d_zvec_initial = nullptr;
    {
        const int K = 1 << k_log;
        const int n_log = m - k_log;
        const long long n_outer = 1LL << n_log, n_stripes = n_outer / 8;
        ch.observe_label((const uint8_t*)"flock-lincheck-v0", 17);
        F128 alpha;
        if (P->lc_alpha_bits > 0) {
            ChF128 a;
            lc_nonces.push_back(ch.grind_pow_and_sample_f128((uint32_t)P->lc_alpha_bits, &a));
            alpha = frch(a);
        } else {
            alpha = frch(ch.sample_f128());
        }
        F128 beta{0, 0}; bool has_pin = P->const_pin_col >= 0;
        if (has_pin) {
            if (P->lc_beta_bits > 0) {
                ChF128 b;
                lc_nonces.push_back(ch.grind_pow_and_sample_f128((uint32_t)P->lc_beta_bits, &b));
                beta = frch(b);
            } else {
                beta = frch(ch.sample_f128());
            }
        }

        static std::once_flag matrix_setup_once;
        static cudaError_t matrix_setup_error = cudaSuccess;
        static uint32_t *d_acp = nullptr, *d_ar = nullptr, *d_bcp = nullptr, *d_br = nullptr;
        static uint32_t setup_a_nnz = 0, setup_b_nnz = 0;
        static int setup_k_log = 0, setup_useful_bits = 0, setup_const_pin = -1;
        static const uint32_t *setup_a_col_ptr = nullptr, *setup_a_rows = nullptr;
        static const uint32_t *setup_b_col_ptr = nullptr, *setup_b_rows = nullptr;
        std::call_once(matrix_setup_once, [&] {
            setup_a_nnz = P->a_nnz; setup_b_nnz = P->b_nnz;
            setup_k_log = P->k_log; setup_useful_bits = P->useful_bits;
            setup_const_pin = P->const_pin_col;
            setup_a_col_ptr = P->a_col_ptr; setup_a_rows = P->a_rows;
            setup_b_col_ptr = P->b_col_ptr; setup_b_rows = P->b_rows;
            matrix_setup_error = cudaMalloc(&d_acp, (K + 1) * sizeof(uint32_t));
            if (matrix_setup_error == cudaSuccess)
                matrix_setup_error = cudaMalloc(&d_ar, (P->a_nnz ? P->a_nnz : 1) * sizeof(uint32_t));
            if (matrix_setup_error == cudaSuccess)
                matrix_setup_error = cudaMalloc(&d_bcp, (K + 1) * sizeof(uint32_t));
            if (matrix_setup_error == cudaSuccess)
                matrix_setup_error = cudaMalloc(&d_br, (P->b_nnz ? P->b_nnz : 1) * sizeof(uint32_t));
            if (matrix_setup_error == cudaSuccess)
                matrix_setup_error = cudaMemcpy(d_acp, P->a_col_ptr, (K + 1) * sizeof(uint32_t), cudaMemcpyHostToDevice);
            if (matrix_setup_error == cudaSuccess && P->a_nnz)
                matrix_setup_error = cudaMemcpy(d_ar, P->a_rows, P->a_nnz * sizeof(uint32_t), cudaMemcpyHostToDevice);
            if (matrix_setup_error == cudaSuccess)
                matrix_setup_error = cudaMemcpy(d_bcp, P->b_col_ptr, (K + 1) * sizeof(uint32_t), cudaMemcpyHostToDevice);
            if (matrix_setup_error == cudaSuccess && P->b_nnz)
                matrix_setup_error = cudaMemcpy(d_br, P->b_rows, P->b_nnz * sizeof(uint32_t), cudaMemcpyHostToDevice);
        });
        CK(matrix_setup_error);
        if (P->a_nnz != setup_a_nnz || P->b_nnz != setup_b_nnz ||
            P->k_log != setup_k_log || P->useful_bits != setup_useful_bits ||
            P->const_pin_col != setup_const_pin ||
            P->a_col_ptr != setup_a_col_ptr || P->a_rows != setup_a_rows ||
            P->b_col_ptr != setup_b_col_ptr || P->b_rows != setup_b_rows) {
            printf("FFI: BLAKE3 lincheck matrix storage changed after setup\n");
            return 104;
        }

        F128 *d_eq_inner, *d_comb, *d_eq_outer, *d_nC, *d_nZ, *d_p1, *d_pinf, *d_e1, *d_einf;
        CK(ffi_malloc(&d_eq_inner, K * sizeof(F128))); CK(ffi_malloc(&d_comb, K * sizeof(F128)));
        CK(ffi_malloc(&d_zvec, K * sizeof(F128))); CK(ffi_malloc(&d_nC, K * sizeof(F128)));
        CK(ffi_malloc(&d_nZ, K * sizeof(F128)));
        CK(ffi_malloc(&d_eq_outer, n_outer * sizeof(F128)));
        CK(ffi_malloc(&d_p1, LC_MAX_BLOCKS * sizeof(F128))); CK(ffi_malloc(&d_pinf, LC_MAX_BLOCKS * sizeof(F128)));
        CK(ffi_malloc(&d_e1, sizeof(F128))); CK(ffi_malloc(&d_einf, sizeof(F128)));

        build_quirky_eq_device(d_eq_inner, zc_z, xab_inner, k_skip);
        CK(cudaGetLastError());
        launch_linear_check_compressed_column_fold(d_eq_inner, d_acp, d_ar, d_bcp, d_br, alpha, K, d_comb);
        CK(cudaGetLastError());
        if (has_pin) {   // comb_vec[pin] += beta
            F128 v; CK(cudaMemcpy(&v, d_comb + P->const_pin_col, sizeof(F128), cudaMemcpyDeviceToHost));
            v = ADD(v, beta);
            CK(cudaMemcpy(d_comb + P->const_pin_col, &v, sizeof(F128), cudaMemcpyHostToDevice));
        }

        build_eq_device(d_eq_outer, xab_outer.data(), n_log);
        CK(cudaGetLastError());
        launch_linear_check_partial_fold(d_zlin, d_eq_outer, n_stripes, K, P->useful_bits, d_zvec);
        CK(cudaGetLastError()); CK(cudaDeviceSynchronize());
        CK(ffi_malloc(&d_zvec_initial, K * sizeof(F128)));
        CK(cudaMemcpy(d_zvec_initial, d_zvec, K * sizeof(F128), cudaMemcpyDeviceToDevice));

        F128 *cC = d_comb, *cZ = d_zvec, *nC = d_nC, *nZ = d_nZ;
        long long L = K;
        for (int rnd = 0; rnd < irl; rnd++) {
            long long half = L / 2;
            launch_linear_check_message(cC, cZ, half, d_p1, d_pinf, d_e1, d_einf);
            CK(cudaGetLastError());
            F128 e1, einf;
            CK(cudaMemcpy(&e1, d_e1, sizeof(F128), cudaMemcpyDeviceToHost));
            CK(cudaMemcpy(&einf, d_einf, sizeof(F128), cudaMemcpyDeviceToHost));
            lc_e1s.push_back(e1); lc_einfs.push_back(einf);
            ch.observe_f128(toch(e1)); ch.observe_f128(toch(einf));
            F128 r;
            if (P->lc_round_bits > 0) {
                ChF128 rc;
                lc_nonces.push_back(ch.grind_pow_and_sample_f128((uint32_t)P->lc_round_bits, &rc));
                r = frch(rc);
            } else {
                r = frch(ch.sample_f128());
            }
            lc_rrounds.push_back(r);
            launch_linear_check_fold_pair(cC, cZ, nC, nZ, half, r);
            CK(cudaGetLastError()); CK(cudaDeviceSynchronize());
            F128* t; t = cC; cC = nC; nC = t; t = cZ; cZ = nZ; nZ = t;
            L = half;
        }
        CK(cudaMemcpy(lc_zpart.data(), cZ, 64 * sizeof(F128), cudaMemcpyDeviceToHost));
        { std::vector<ChF128> s(64); for (int i = 0; i < 64; i++) s[i] = toch(lc_zpart[i]);
          ch.observe_f128_slice(s.data(), 64); }
        if (P->lc_skip_bits > 0) {
            ChF128 rs_;
            lc_nonces.push_back(ch.grind_pow_and_sample_f128((uint32_t)P->lc_skip_bits, &rs_));
            lc_rskip = frch(rs_);
        } else {
            lc_rskip = frch(ch.sample_f128());
        }
        { vector<F128> lam = lagrange_weights_host(k_skip, lc_rskip);
          lc_w = F128{0, 0};
          for (int i = 0; i < 64; i++) lc_w = ADD(lc_w, MUL(lam[i], lc_zpart[i])); }

        ffi_free(d_eq_inner); ffi_free(d_comb); ffi_free(d_zvec); ffi_free(d_nC); ffi_free(d_nZ);
        ffi_free(d_eq_outer);
        ffi_free(d_p1); ffi_free(d_pinf); ffi_free(d_e1); ffi_free(d_einf);
    }
    ffi_free(d_zlin);
    // lincheck proof section
    W.u64(lc_e1s.size());
    for (size_t i = 0; i < lc_e1s.size(); i++) { W.f128(lc_e1s[i]); W.f128(lc_einfs[i]); }
    W.f128s(lc_zpart);
    W.u64(lc_nonces.size());
    for (uint64_t n : lc_nonces) W.u64(n);

    // r_inner_rest = reverse(rounds)
    vector<F128> r_inner_rest(lc_rrounds.rbegin(), lc_rrounds.rend());

    // ================= ring-switch batch ====================================
    // x_full per claim: ab = r_inner_rest ++ xab_outer; c = zc_r[6..].
    vector<F128> xfull_ab; xfull_ab.reserve(m - 6);
    xfull_ab.insert(xfull_ab.end(), r_inner_rest.begin(), r_inner_rest.end());
    xfull_ab.insert(xfull_ab.end(), xab_outer.begin(), xab_outer.end());
    vector<F128> xfull_c(zc_r.begin() + 6, zc_r.end());

    // s_hat_v_ab from z_vec: s[b] = Σ_k eq(tail)[k]·z_vec[k*128+b], tail = r_inner_rest[1..]
    vector<F128> shat_ab(128), shat_c(128);
    F128 *d_eq_shat_ab, *d_shat_ab, *d_suffix_ab, *d_suffix_c, *d_shat_c, *d_shat_partials;
    const int shat_ab_tail_len = 1 << (irl - 1);
    CK(ffi_malloc(&d_eq_shat_ab, shat_ab_tail_len * sizeof(F128)));
    CK(ffi_malloc(&d_shat_ab, 128 * sizeof(F128)));
    build_eq_device(d_eq_shat_ab, r_inner_rest.data() + 1, irl - 1);
    ring_switch_fold_witness_evaluations<<<128, 128>>>(d_zvec_initial, d_eq_shat_ab, shat_ab_tail_len, d_shat_ab);
    CK(cudaGetLastError());
    CK(cudaMemcpy(shat_ab.data(), d_shat_ab, 128 * sizeof(F128), cudaMemcpyDeviceToHost));
    CK(ffi_free(d_eq_shat_ab)); CK(ffi_free(d_shat_ab)); CK(ffi_free(d_zvec_initial));
    const int ring_switch_chunks = 64;
    CK(ffi_malloc(&d_suffix_ab, len * sizeof(F128)));
    CK(ffi_malloc(&d_suffix_c, len * sizeof(F128)));
    CK(ffi_malloc(&d_shat_c, 128 * sizeof(F128)));
    CK(ffi_malloc(&d_shat_partials, 128 * ring_switch_chunks * sizeof(F128)));
    build_eq_device(d_suffix_ab, xfull_ab.data() + 1, (int)xfull_ab.size() - 1);
    build_eq_device(d_suffix_c, xfull_c.data() + 1, (int)xfull_c.size() - 1);
    ring_switch_fold_rows_grouped<<<dim3(ring_switch_chunks, 16), 256>>>(
        df, d_suffix_c, len, ring_switch_chunks, d_shat_partials);
    ring_switch_fold_rows_reduce<<<128, 256>>>(d_shat_partials, ring_switch_chunks, d_shat_c);
    CK(cudaGetLastError());
    CK(cudaMemcpy(shat_c.data(), d_shat_c, 128 * sizeof(F128), cudaMemcpyDeviceToHost));
    CK(ffi_free(d_shat_c));
    CK(ffi_free(d_shat_partials));

    ch.observe_label((const uint8_t*)"flock-pcs-open-batch-v0", 23);
    struct RsWork { vector<F128> shat, eq_rd; F128 claim; uint64_t nonce; };
    RsWork rsw[2];
    const vector<F128>* shats[2] = { &shat_ab, &shat_c };
    for (int i = 0; i < 2; i++) {
        ch.observe_label((const uint8_t*)"flock-ring-switch-v0", 20);
        { std::vector<ChF128> s(128); for (int j = 0; j < 128; j++) s[j] = toch((*shats[i])[j]);
          ch.observe_f128_slice(s.data(), 128); }
        // PoW before the ring-switch point r'' (omitted ENTIRELY at 0 bits —
        // unlike the ladder's grinds, this site has no 0-bit nonce absorb).
        std::vector<ChF128> rd(7);
        rsw[i].nonce = 0;
        if (P->rs_bits > 0)
            rsw[i].nonce = ch.grind_pow_and_sample_f128_vec((uint32_t)P->rs_bits, rd.data(), 7);
        else
            ch.sample_f128_vec(rd.data(), 7);
        vector<F128> rdf(7); for (int j = 0; j < 7; j++) rdf[j] = frch(rd[j]);
        rsw[i].shat = *shats[i];
        rsw[i].eq_rd = build_eq_host(rdf.data(), 7);
        vector<F128> shat_u = ta_transpose_host(*shats[i]);
        F128 c{0, 0};
        for (int j = 0; j < 128; j++) c = ADD(c, MUL(shat_u[j], rsw[i].eq_rd[j]));
        rsw[i].claim = c;
    }
    // The γ batch coefficients: ONE two-word vec squeeze (grind-fused when the
    // claim-batch policy is on; batching_nonces carries the single nonce).
    vector<uint64_t> batching_nonces;
    F128 gam[2];
    {
        ChF128 g[2];
        if (P->gamma_bits > 0)
            batching_nonces.push_back(ch.grind_pow_and_sample_f128_vec((uint32_t)P->gamma_bits, g, 2));
        else
            ch.sample_f128_vec(g, 2);
        gam[0] = frch(g[0]); gam[1] = frch(g[1]);
    }
    F128 target = ADD(MUL(gam[0], rsw[0].claim), MUL(gam[1], rsw[1].claim));

    // Build the combined basis on the device. Keep it resident for sumcheck.
    vector<F128> weights_ab(128), weights_c(128);
    for (int j = 0; j < 128; j++) {
        weights_ab[j] = MUL(gam[0], rsw[0].eq_rd[j]);
        weights_c[j] = MUL(gam[1], rsw[1].eq_rd[j]);
    }
    F128 *d_weights_ab, *d_weights_c, *dcb;
    CK(ffi_malloc(&d_weights_ab, 128 * sizeof(F128)));
    CK(ffi_malloc(&d_weights_c, 128 * sizeof(F128)));
    CK(ffi_malloc(&dcb, len * sizeof(F128)));
    CK(cudaMemcpy(d_weights_ab, weights_ab.data(), 128 * sizeof(F128), cudaMemcpyHostToDevice));
    CK(cudaMemcpy(d_weights_c, weights_c.data(), 128 * sizeof(F128), cudaMemcpyHostToDevice));
    ring_switch_combine_basis<<<(unsigned)((len + 255) / 256), 256>>>(
        d_suffix_ab, d_suffix_c, d_weights_ab, d_weights_c, len, dcb);
    CK(cudaGetLastError());
    CK(ffi_free(d_suffix_ab)); CK(ffi_free(d_suffix_c));
    CK(ffi_free(d_weights_ab)); CK(ffi_free(d_weights_c));

    // Round-0 message over (witness, combined basis) — the `round0_prime` the
    // Rust combine pass hands the ladder (the L0 OOD loop then β-batches into
    // it inside run_ligerito_f256, exactly as the Rust driver does).
    F128 first_u0, first_u2;
    {
        F128 *p0, *p2, *du0, *du2;
        CK(ffi_malloc(&p0, SMC_MAX_BLOCKS * sizeof(F128)));
        CK(ffi_malloc(&p2, SMC_MAX_BLOCKS * sizeof(F128)));
        CK(ffi_malloc(&du0, sizeof(F128))); CK(ffi_malloc(&du2, sizeof(F128)));
        launch_sumcheck_message(df, dcb, len / 2, p0, p2, du0, du2);
        CK(cudaGetLastError());
        CK(cudaMemcpy(&first_u0, du0, sizeof(F128), cudaMemcpyDeviceToHost));
        CK(cudaMemcpy(&first_u2, du2, sizeof(F128), cudaMemcpyDeviceToHost));
        CK(ffi_free(p0)); CK(ffi_free(p2)); CK(ffi_free(du0)); CK(ffi_free(du2));
    }
    // ring-switch proof section (each claim: s_hat_v + its r'' PoW nonce),
    // then the γ batching nonce list.
    W.f128s(shat_ab); W.u64(rsw[0].nonce);
    W.f128s(shat_c); W.u64(rsw[1].nonce);
    W.u64(batching_nonces.size());
    for (uint64_t n : batching_nonces) W.u64(n);

    // ================= ligerito recursion: the F256 fold ladder =============
    // (ligerito_f256.cuh — port of extension.rs::recursive_prover_with_basis_impl;
    // capped Merkle, stratified queries, claim/consistency PoW, code switches.)
    LigF256Proof lig;
    {
        LigF256Config LC;
        LC.log_n = log_n;
        LC.initial_k = P->initial_k;
        LC.recursive_steps = P->recursive_steps;
        LC.log_inv_rates = P->log_inv_rates;
        LC.recursive_ks = P->recursive_ks;
        LC.queries = P->queries;
        LC.grinding_bits = P->grinding_bits;
        LC.claim_batch_grinding_bits = P->claim_batch_grinding_bits;
        LC.consistency_batch_grinding_bits = P->consistency_batch_grinding_bits;
        LC.ood_samples = P->ood_samples;
        LigAlloc arena{lig_arena_alloc, lig_arena_release};
        int rc = run_ligerito_f256(LC, ch, target, first_u0, first_u2, df, dcb,
                                   d_cw0, d_tree0, l0_bl, l0_ni, arena, lig);
        if (rc != 0) { printf("FFI: ligerito F256 ladder failed (%d)\n", rc); return rc; }
    }
    ffi_free(d_cw0); ffi_free(d_tree0);
    ffi_free(df); ffi_free(dcb);

    // ================= ligerito proof section ===============================
    // recursive caps (levels 1..r), each absorbed flattened.
    W.u64(lig.recursive_caps.size());
    for (auto& cap : lig.recursive_caps) W.hashes(cap);
    // level opens: L0, then trees 1..r-1, then the final tree — each rows +
    // capped per-query paths.
    auto write_open = [&](const LigLevelOpen& lo) {
        W.rows(lo.rows_flat, lo.n_rows, lo.row_len);
        W.hashes(lo.path);
    };
    W.u64(2 + lig.recursive_opens.size());
    write_open(lig.initial_open);
    for (auto& lo : lig.recursive_opens) write_open(lo);
    write_open(lig.final_open);
    W.f128s(lig.yr);
    // sumcheck_transcript_f256: (u0.c0, u0.c1, u2.c0, u2.c1) per message.
    W.u64(lig.transcript.size());
    for (auto& msg : lig.transcript) {
        W.f128(msg.u0.c0); W.f128(msg.u0.c1);
        W.f128(msg.u2.c0); W.f128(msg.u2.c1);
    }
    W.f128s(lig.ood_values);
    W.u64(lig.grinding_nonces.size());
    for (auto n : lig.grinding_nonces) W.u64(n);
    W.u64(lig.claim_batch_nonces.size());
    for (auto n : lig.claim_batch_nonces) W.u64(n);
    W.u64(lig.consistency_batch_nonces.size());
    for (auto n : lig.consistency_batch_nonces) W.u64(n);

    *out_len = W.buf.size();
    *out = (uint8_t*)malloc(W.buf.size());
    memcpy(*out, W.buf.data(), W.buf.size());
    CK(device_arena.finish());
    return 0;
}

} // extern "C"
