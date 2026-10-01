// Tables for the canonical CPU-structured zerocheck round-1 kernel.
#pragma once
#include "f128.cuh"
#include <cstdint>

static uint8_t* g_zc_f8mul = nullptr;
static F128* g_zc_phi = nullptr;
static u64* g_zc_t0 = nullptr;

inline cudaError_t upload_zerocheck_first_round_tables(const uint8_t* mcol, const uint8_t* f8mul,
                                           const F128* phi8_256) {
    u64 mpacked[64 * 8];
    for (int column = 0; column < 64; column++) {
        for (int word = 0; word < 8; word++) {
            u64 value = 0;
            for (int byte = 0; byte < 8; byte++) {
                value |= (u64)mcol[column * 64 + word * 8 + byte] << (8 * byte);
            }
            mpacked[column * 8 + word] = value;
        }
    }

    if (!g_zc_f8mul) {
        cudaError_t err = cudaMalloc(&g_zc_f8mul, (size_t)256 * 256);
        if (err != cudaSuccess) return err;
    }
    cudaError_t err =
        cudaMemcpy(g_zc_f8mul, f8mul, (size_t)256 * 256, cudaMemcpyHostToDevice);
    if (err != cudaSuccess) return err;

    if (!g_zc_phi) {
        err = cudaMalloc(&g_zc_phi, 256 * sizeof(F128));
        if (err != cudaSuccess) return err;
    }
    err = cudaMemcpy(g_zc_phi, phi8_256, 256 * sizeof(F128), cudaMemcpyHostToDevice);
    if (err != cudaSuccess) return err;

    u64 t0[256 * 8];
    for (int value = 0; value < 256; value++) {
        for (int word = 0; word < 8; word++) {
            u64 acc = 0;
            for (int bit = 0; bit < 8; bit++) {
                if ((value >> bit) & 1) acc ^= mpacked[bit * 8 + word];
            }
            t0[value * 8 + word] = acc;
        }
    }
    if (!g_zc_t0) {
        err = cudaMalloc(&g_zc_t0, sizeof(t0));
        if (err != cudaSuccess) return err;
    }
    return cudaMemcpy(g_zc_t0, t0, sizeof(t0), cudaMemcpyHostToDevice);
}
