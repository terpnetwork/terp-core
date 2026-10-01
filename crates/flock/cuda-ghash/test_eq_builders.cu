// Device eq builders vs the HOST reference builders in lincheck.cuh.
//
// bench_ligerito builds both eq tables on device (the host form is ~350 ns per
// GF(2^128) mul, ~100 ms for a 2^18 table). The host builders remain the
// reference the vector tests check against, so this pins the device forms to
// them. No Rust oracle needed: the host builders ARE the oracle.
//
// Covers both build_eq_device branches (direct kernel d<=12, doubling d>12) and
// the BLAKE3 quirky-eq shape (k_skip=6, inner_rest=8).
//
// Build: make test_eq_builders      Run: ./test_eq_builders
#include <cstdio>
#include <vector>
#include "f128.cuh"
#include "lincheck.cuh"
#include "induce_sumcheck.cuh"

#define CK(x) do { cudaError_t e=(x); if(e){ printf("CUDA err %s @%d\n", cudaGetErrorString(e), __LINE__); return 1;} } while(0)

static int fails = 0;
static void cmp(const char* what, const std::vector<F128>& h, const std::vector<F128>& d) {
    if (h.size() != d.size()) { printf("FAIL %s: size %zu vs %zu\n", what, h.size(), d.size()); fails++; return; }
    for (size_t i = 0; i < h.size(); i++)
        if (h[i].lo != d[i].lo || h[i].hi != d[i].hi) {
            printf("FAIL %s: [%zu] host %016llx%016llx != dev %016llx%016llx\n", what, i,
                   (unsigned long long)h[i].hi, (unsigned long long)h[i].lo,
                   (unsigned long long)d[i].hi, (unsigned long long)d[i].lo);
            fails++; return;
        }
    printf("  ok  %-28s %zu entries bit-identical\n", what, h.size());
}

static F128 pseudo(int i) { return F128{(u64)(i*2654435761ull+0x9E37), (u64)(i*40503ull+7)}; }

int main() {
    // eq table: cover both build_eq_device branches (direct kernel d<=12, doubling d>12)
    for (int d : {1, 4, 8, 12, 13, 15, 18, 19}) {
        std::vector<F128> pt(d); for (int i = 0; i < d; i++) pt[i] = pseudo(i + d);
        std::vector<F128> href = build_eq_table_host(pt);
        F128* dev; CK(cudaMalloc(&dev, href.size() * sizeof(F128)));
        build_eq_device(dev, pt.data(), d);
        CK(cudaDeviceSynchronize());
        std::vector<F128> got(href.size());
        CK(cudaMemcpy(got.data(), dev, got.size() * sizeof(F128), cudaMemcpyDeviceToHost));
        char nm[64]; snprintf(nm, sizeof nm, "build_eq d=%d", d);
        cmp(nm, href, got);
        CK(cudaFree(dev));
    }
    // quirky eq: BLAKE3 uses k_skip=6, inner_rest_len=8; vary both
    for (int k_skip : {2, 4, 6}) for (int rest : {0, 3, 8}) {
        F128 z = pseudo(k_skip * 31 + rest);
        std::vector<F128> xr(rest); for (int i = 0; i < rest; i++) xr[i] = pseudo(i + 100);
        std::vector<F128> href = build_quirky_eq_table_host(z, xr, k_skip);
        F128* dev; CK(cudaMalloc(&dev, href.size() * sizeof(F128)));
        build_quirky_eq_device(dev, z, xr, k_skip);
        CK(cudaDeviceSynchronize());
        std::vector<F128> got(href.size());
        CK(cudaMemcpy(got.data(), dev, got.size() * sizeof(F128), cudaMemcpyDeviceToHost));
        char nm[64]; snprintf(nm, sizeof nm, "quirky_eq k_skip=%d rest=%d", k_skip, rest);
        cmp(nm, href, got);
        CK(cudaFree(dev));
    }
    printf(fails ? "\nFAILED (%d)\n" : "\nall eq builders match\n", fails);
    return fails ? 1 : 0;
}
