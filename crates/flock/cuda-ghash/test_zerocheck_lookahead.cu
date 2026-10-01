// Zerocheck multilinear chain: two-round lookahead vs one round per pass.
//
// The lookahead folds twice per pass and reconstructs the second round's message
// by interpolating a quadratic in the first round's challenge, so a mistake shows
// up as a diverged transcript rather than a wrong-looking number. This replays
// the whole chain both ways over identical inputs under one deterministic
// challenger and compares every rho plus the final bound element.
//
// No Rust oracle needed: the one-round-per-pass chain is the reference, and it is
// itself pinned to flock by test_zerocheck_full. Exercises the round-2 kernel's
// hi-factored and per-point eq paths (rows=2^14 takes the fallback) and both
// hand-offs to the single-round remainder.
//
// Build: make test_zerocheck_lookahead      Run: ./test_zerocheck_lookahead
#include <cstdio>
#include <cstdlib>
#include <vector>
#include "f128.cuh"
#include "ntt_host.hpp"
#include "zerocheck_tail.cuh"
#include "zerocheck_round2.cuh"

#define CK(x) do { cudaError_t e=(x); if(e){ printf("CUDA err %s @%d\n", cudaGetErrorString(e), __LINE__); exit(1);} } while(0)

static F128 mix(F128 m1, F128 mi) {                 // stand-in for FsChallenger
    F128 k1{0xA5A5F00D12345678ull, 0x0F1E2D3C4B5A6978ull};
    F128 k2{0x1122334455667788ull, 0x99AABBCCDDEEFF01ull};
    return f128_add_hd(f128_mul_hd(m1, k1), f128_mul_hd(mi, k2));
}
static F128 interp3(F128 h0, F128 h1, F128 hinf, F128 rho) {
    F128 c1 = f128_add_hd(f128_add_hd(h0, h1), hinf);
    return f128_add_hd(h0, f128_mul_hd(rho, f128_add_hd(c1, f128_mul_hd(rho, hinf))));
}
__global__ void fill_f128(F128* p, long long n, unsigned seed) {
    long long i = blockIdx.x * (long long)blockDim.x + threadIdx.x;
    if (i >= n) return;
    unsigned long long s = (unsigned long long)i * 0x9E3779B97F4A7C15ull + seed;
    s ^= s >> 29; s *= 0xBF58476D1CE4E5B9ull;
    p[i] = F128{s, s * 0x94D049BB133111EBull + seed};
}
__global__ void fill_bytes(uint8_t* p, long long n, unsigned seed) {
    long long i = blockIdx.x * (long long)blockDim.x + threadIdx.x;
    if (i >= n) return;
    unsigned long long s = (unsigned long long)i * 0x9E3779B97F4A7C15ull + seed;
    s ^= s >> 29; s *= 0xBF58476D1CE4E5B9ull; s ^= s >> 32;
    p[i] = (uint8_t)s;
}

int main() {
    int fails = 0;
    for (int nlog : {14, 18, 22}) for (long long FIN : {(long long)0, (long long)1024})
    {
        const int LOOK = 1;
        long long rows = 1LL << nlog;
        int n_mlv = nlog, n_tail = n_mlv - 1;
        int zt_dfull = nlog, lobits = zt_dfull > 7 ? zt_dfull - 7 : 0;
        const F128 ONE{1, 0};

        uint8_t *da, *db; F128 *dft, *eqlo, *eqhi;
        CK(cudaMalloc(&da, rows * 8)); CK(cudaMalloc(&db, rows * 8));
        CK(cudaMalloc(&dft, 8 * 256 * sizeof(F128)));
        CK(cudaMalloc(&eqlo, (1LL << lobits) * sizeof(F128)));
        CK(cudaMalloc(&eqhi, (1LL << (zt_dfull - lobits)) * sizeof(F128)));
        fill_bytes<<<(unsigned)((rows * 8 + 255) / 256), 256>>>(da, rows * 8, 1);
        fill_bytes<<<(unsigned)((rows * 8 + 255) / 256), 256>>>(db, rows * 8, 7);
        fill_f128<<<8, 256>>>(dft, 8 * 256, 3);
        fill_f128<<<(unsigned)(((1LL << lobits) + 255) / 256), 256>>>(eqlo, 1LL << lobits, 17);
        fill_f128<<<(unsigned)(((1LL << (zt_dfull - lobits)) + 255) / 256), 256>>>(
            eqhi, 1LL << (zt_dfull - lobits), 23);

        F128 *am, *bm, *amn, *bmn, *p1, *pinf, *m1d, *minfd, *part8, *out8;
        CK(cudaMalloc(&am, rows * sizeof(F128)));  CK(cudaMalloc(&bm, rows * sizeof(F128)));
        CK(cudaMalloc(&amn, rows * sizeof(F128))); CK(cudaMalloc(&bmn, rows * sizeof(F128)));
        CK(cudaMalloc(&p1, ZT_MAX_BLOCKS * sizeof(F128)));
        CK(cudaMalloc(&pinf, ZT_MAX_BLOCKS * sizeof(F128)));
        CK(cudaMalloc(&m1d, sizeof(F128))); CK(cudaMalloc(&minfd, sizeof(F128)));
        CK(cudaMalloc(&part8, 8 * ZT_MAX_BLOCKS * sizeof(F128)));
        CK(cudaMalloc(&out8, 8 * sizeof(F128)));

        std::vector<F128> sc(n_tail + 2);
        for (int j = 0; j < (int)sc.size(); j++)
            sc[j] = F128{0x1000000000000001ull * (j + 1) + 3, 0x77ull * (j + 2)};

        // ---------- reference ----------
        std::vector<F128> refr; F128 reffinal;
        {
            F128 *cA = am, *cB = bm, *nA = amn, *nB = bmn;
            launch_zerocheck_second_round_fold(da, db, dft, rows, cA, cB);
            launch_zerocheck_tail_message(cA, cB, eqlo, eqhi, 0, lobits, rows / 2, ONE, p1, pinf, m1d, minfd);
            CK(cudaDeviceSynchronize());
            F128 a, b; CK(cudaMemcpy(&a, m1d, sizeof(F128), cudaMemcpyDeviceToHost));
            CK(cudaMemcpy(&b, minfd, sizeof(F128), cudaMemcpyDeviceToHost));
            refr.push_back(mix(a, b));
            long long L = rows;
            for (int i = 0; i < n_tail; i++) {
                launch_zerocheck_tail_fold_and_message(cA, cB, nA, nB, eqlo, eqhi, i + 1, lobits, L / 4,
                                         refr.back(), sc[i], p1, pinf, m1d, minfd);
                { F128* t = cA; cA = nA; nA = t; t = cB; cB = nB; nB = t; }
                L /= 2;
                CK(cudaDeviceSynchronize());
                CK(cudaMemcpy(&a, m1d, sizeof(F128), cudaMemcpyDeviceToHost));
                CK(cudaMemcpy(&b, minfd, sizeof(F128), cudaMemcpyDeviceToHost));
                refr.push_back(mix(a, b));
            }
            launch_sumcheck_fold(cA, cB, nA, nB, L / 2, refr.back());
            CK(cudaDeviceSynchronize());
            CK(cudaMemcpy(&reffinal, nA, sizeof(F128), cudaMemcpyDeviceToHost));
        }

        // ---------- lookahead from round 1 on ----------
        std::vector<F128> gotr; F128 gotfinal; int passes = 0;
        {
            F128 *cA = am, *cB = bm, *nA = amn, *nB = bmn;
            F128 h[8];
            if (LOOK) {
                launch_zerocheck_second_round_fold_with_lookahead(da, db, dft, eqlo, eqhi, lobits, rows, cA, cB,
                                           sc[0], part8, out8);
                CK(cudaDeviceSynchronize());
                CK(cudaMemcpy(h, out8, 8 * sizeof(F128), cudaMemcpyDeviceToHost));
                F128 rho0 = mix(h[0], h[1]);
                gotr.push_back(rho0);
                gotr.push_back(mix(interp3(h[2], h[3], h[4], rho0), interp3(h[5], h[6], h[7], rho0)));
            }

            long long L = rows; int i = 0, k = 2;
            while (k + 1 <= n_tail) {
                long long out_quads = L / 16;
                if (out_quads <= FIN) break;
                launch_zerocheck_tail_lookahead(cA, cB, nA, nB, eqlo, eqhi, k, lobits, out_quads,
                                    gotr[gotr.size() - 2], gotr.back(),
                                    sc[k - 1], sc[k], part8, out8);
                { F128* t = cA; cA = nA; nA = t; t = cB; cB = nB; nB = t; }
                L /= 4;
                CK(cudaDeviceSynchronize());
                CK(cudaMemcpy(h, out8, 8 * sizeof(F128), cudaMemcpyDeviceToHost));
                F128 rk = mix(h[0], h[1]);
                gotr.push_back(rk);
                gotr.push_back(mix(interp3(h[2], h[3], h[4], rk), interp3(h[5], h[6], h[7], rk)));
                passes++; k += 2;
            }
            if (k > 1) {
                launch_sumcheck_fold(cA, cB, nA, nB, L / 2, gotr[gotr.size() - 2]);
                { F128* t = cA; cA = nA; nA = t; t = cB; cB = nB; nB = t; }
                L /= 2; i = k - 1;
            }
            for (; i < n_tail; i++) {
                launch_zerocheck_tail_fold_and_message(cA, cB, nA, nB, eqlo, eqhi, i + 1, lobits, L / 4,
                                         gotr.back(), sc[i], p1, pinf, m1d, minfd);
                { F128* t = cA; cA = nA; nA = t; t = cB; cB = nB; nB = t; }
                L /= 2;
                F128 a, b; CK(cudaDeviceSynchronize());
                CK(cudaMemcpy(&a, m1d, sizeof(F128), cudaMemcpyDeviceToHost));
                CK(cudaMemcpy(&b, minfd, sizeof(F128), cudaMemcpyDeviceToHost));
                gotr.push_back(mix(a, b));
            }
            launch_sumcheck_fold(cA, cB, nA, nB, L / 2, gotr.back());
            CK(cudaDeviceSynchronize());
            CK(cudaMemcpy(&gotfinal, nA, sizeof(F128), cudaMemcpyDeviceToHost));
        }

        int bad = 0;
        if ((int)refr.size() != n_mlv) { printf("  ref produced %zu rhos, expected %d\n", refr.size(), n_mlv); bad = 1; }
        if (refr.size() != gotr.size()) { printf("  rho count %zu vs %zu\n", refr.size(), gotr.size()); bad = 1; }
        else for (size_t j = 0; j < refr.size(); j++)
            if (refr[j].lo != gotr[j].lo || refr[j].hi != gotr[j].hi) { printf("  rho[%zu] differs\n", j); bad = 1; break; }
        if (reffinal.lo != gotfinal.lo || reffinal.hi != gotfinal.hi) { printf("  final elem differs\n"); bad = 1; }
        fails += bad;
        printf("  %s rows=2^%-2d n_mlv=%-2d finish=%-5lld mode=%s passes=%-2d  %zu rhos + final match\n",
               bad ? "BAD" : "ok ", nlog, n_mlv, FIN, "lookahead@r1", passes, refr.size());

        cudaFree(da); cudaFree(db); cudaFree(dft); cudaFree(eqlo); cudaFree(eqhi);
        cudaFree(am); cudaFree(bm); cudaFree(amn); cudaFree(bmn);
        cudaFree(p1); cudaFree(pinf); cudaFree(m1d); cudaFree(minfd);
        cudaFree(part8); cudaFree(out8);
    }
    printf(fails ? "\nFAILED (%d)\n" : "\nzerocheck transcript identical to the one-round-per-pass chain\n", fails);
    return fails ? 1 : 0;
}
