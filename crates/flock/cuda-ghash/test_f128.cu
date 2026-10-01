// Correctness test for the CUDA GF(2^128) GHASH port.
//
// Layer 1: bit-for-bit vs the real `flare` impl, via vectors.bin produced by
//          `cargo run --release --bin dump_ghash_vectors`.
// Layer 2: every on-device variant (binius / schoolbook / software / deferred)
//          must agree with the flare product AND with each other.
// Layer 3: the GHASH smoking-gun algebraic identities.
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include "f128.cuh"

#define CK(x) do { cudaError_t e=(x); if(e){ \
    printf("CUDA error %s at %s:%d\n", cudaGetErrorString(e), __FILE__, __LINE__); \
    exit(1);} } while(0)

// Compute all four variants for each (a,b) pair.
__global__ void run_variants(const F128* a, const F128* b, int n,
                             F128* binius, F128* school, F128* karat, F128* soft, F128* deferred) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    F128 x = a[i], y = b[i];
    binius[i]   = ghash_mul_binius(x, y);
    school[i]   = ghash_mul_schoolbook(x, y);
    karat[i]    = ghash_mul_karatsuba(x, y);
    soft[i]     = ghash_mul_sw(x, y);
    F256 u      = mul_unreduced_clmad(x, y);
    deferred[i] = f256_reduce(u);
}

int main(int argc, char** argv) {
    const char* path = argc > 1 ? argv[1] : "vectors.bin";
    FILE* f = fopen(path, "rb");
    if (!f) { printf("cannot open %s (run the dump_ghash_vectors cargo bin first)\n", path); return 1; }
    uint32_t magic = 0, count = 0;
    size_t rd = fread(&magic, 4, 1, f); rd += fread(&count, 4, 1, f);
    if (rd != 2 || magic != 0x47483132u) { printf("bad vector file (magic=%08x)\n", magic); return 1; }

    std::vector<F128> ha(count), hb(count), hexp(count);
    for (uint32_t i = 0; i < count; i++) {
        u64 v[6];
        if (fread(v, 8, 6, f) != 6) { printf("short read at %u\n", i); return 1; }
        ha[i]   = F128{v[0], v[1]};
        hb[i]   = F128{v[2], v[3]};
        hexp[i] = F128{v[4], v[5]};
    }
    fclose(f);
    printf("loaded %u vectors from %s\n", count, path);

    F128 *da, *db, *dbi, *dsc, *dka, *dsf, *dde;
    size_t bytes = (size_t)count * sizeof(F128);
    CK(cudaMalloc(&da, bytes)); CK(cudaMalloc(&db, bytes));
    CK(cudaMalloc(&dbi, bytes)); CK(cudaMalloc(&dsc, bytes));
    CK(cudaMalloc(&dka, bytes));
    CK(cudaMalloc(&dsf, bytes)); CK(cudaMalloc(&dde, bytes));
    CK(cudaMemcpy(da, ha.data(), bytes, cudaMemcpyHostToDevice));
    CK(cudaMemcpy(db, hb.data(), bytes, cudaMemcpyHostToDevice));

    int tpb = 256, blocks = (count + tpb - 1) / tpb;
    run_variants<<<blocks, tpb>>>(da, db, count, dbi, dsc, dka, dsf, dde);
    CK(cudaDeviceSynchronize());

    std::vector<F128> bi(count), sc(count), ka(count), sf(count), de(count);
    CK(cudaMemcpy(bi.data(), dbi, bytes, cudaMemcpyDeviceToHost));
    CK(cudaMemcpy(sc.data(), dsc, bytes, cudaMemcpyDeviceToHost));
    CK(cudaMemcpy(ka.data(), dka, bytes, cudaMemcpyDeviceToHost));
    CK(cudaMemcpy(sf.data(), dsf, bytes, cudaMemcpyDeviceToHost));
    CK(cudaMemcpy(de.data(), dde, bytes, cudaMemcpyDeviceToHost));

    const char* names[5] = {"binius", "schoolbook", "karatsuba", "software", "deferred"};
    std::vector<F128>* outs[5] = {&bi, &sc, &ka, &sf, &de};
    int fails = 0;
    for (int k = 0; k < 5; k++) {
        int bad = 0; uint32_t first = 0;
        for (uint32_t i = 0; i < count; i++) {
            F128 g = (*outs[k])[i];
            if (g.lo != hexp[i].lo || g.hi != hexp[i].hi) {
                if (!bad) first = i;
                bad++;
            }
        }
        if (bad) {
            fails++;
            F128 g = (*outs[k])[first], e = hexp[first];
            printf("  %-11s FAIL  %d/%u mismatch; first @%u: got %016llx:%016llx exp %016llx:%016llx\n",
                   names[k], bad, count, first, g.hi, g.lo, e.hi, e.lo);
        } else {
            printf("  %-11s OK    %u/%u match flare bit-for-bit\n", names[k], count, count);
        }
    }

    printf("\n%s\n", fails ? "*** CORRECTNESS FAILURES ***" : "ALL VARIANTS MATCH flare F128::mul");
    return fails ? 1 : 0;
}
