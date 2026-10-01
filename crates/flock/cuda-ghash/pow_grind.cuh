#pragma once

#include <cstdint>
#include <climits>
#include "sha256.cuh"
#include "challenger.hpp"

__device__ __forceinline__ uint32_t swap_proof_of_work_word_bytes(uint32_t x) {
    return ((x & 0x000000ffu) << 24) | ((x & 0x0000ff00u) << 8) |
           ((x & 0x00ff0000u) >> 8) | ((x & 0xff000000u) >> 24);
}

__device__ __forceinline__ bool sha256_has_leading_zero_bits(const uint32_t hash[8], uint32_t bits) {
    uint32_t full_words = bits / 32;
    uint32_t extra = bits % 32;
    for (uint32_t i = 0; i < full_words; i++) if (hash[i] != 0) return false;
    return extra == 0 || (hash[full_words] >> (32 - extra)) == 0;
}

__global__ void search_sha256_proof_of_work_nonce(const uint8_t* __restrict__ state_digest, uint64_t start,
                                uint64_t count, uint32_t bits,
                                unsigned long long* __restrict__ best) {
    uint64_t offset = (uint64_t)blockIdx.x * blockDim.x + threadIdx.x;
    uint64_t stride = (uint64_t)gridDim.x * blockDim.x;
    for (; offset < count; offset += stride) {
        uint64_t nonce = start + offset;
        uint32_t hash[8] = {0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
                            0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u};
        uint32_t words[16];
#pragma unroll
        for (int i = 0; i < 8; i++) words[i] = load_be32(state_digest + 4 * i);
        words[8] = swap_proof_of_work_word_bytes((uint32_t)nonce);
        words[9] = swap_proof_of_work_word_bytes((uint32_t)(nonce >> 32));
        words[10] = 0x80000000u;
#pragma unroll
        for (int i = 11; i < 15; i++) words[i] = 0;
        words[15] = 40 * 8;
        sha256_compress_words(hash, words);
        if (sha256_has_leading_zero_bits(hash, bits)) atomicMin(best, (unsigned long long)nonce);
    }
}

inline cudaError_t grind_pow_device(FsChallenger& challenger, uint32_t bits, uint64_t& nonce) {
    if (bits > 256) return cudaErrorInvalidValue;
    if (bits == 0) {
        nonce = 0;
    } else {
        uint8_t state_digest[32];
        { Sha256 state = challenger.hasher; state.finalize(state_digest); }

        static uint8_t* d_state_digest = nullptr;
        static unsigned long long* d_best = nullptr;
        if (!d_state_digest) {
            cudaError_t err = cudaMalloc(&d_state_digest, 32);
            if (err != cudaSuccess) return err;
            err = cudaMalloc(&d_best, sizeof(unsigned long long));
            if (err != cudaSuccess) {
                cudaFree(d_state_digest);
                d_state_digest = nullptr;
                return err;
            }
        }
        cudaError_t err = cudaMemcpy(d_state_digest, state_digest, 32, cudaMemcpyHostToDevice);
        if (err != cudaSuccess) return err;

        const uint64_t chunk = 1ull << 20;
        uint64_t start = 0;
        for (;;) {
            unsigned long long best = ULLONG_MAX;
            err = cudaMemcpy(d_best, &best, sizeof(best), cudaMemcpyHostToDevice);
            if (err != cudaSuccess) return err;
            search_sha256_proof_of_work_nonce<<<1024, 256>>>(d_state_digest, start, chunk, bits, d_best);
            err = cudaGetLastError();
            if (err != cudaSuccess) return err;
            err = cudaMemcpy(&best, d_best, sizeof(best), cudaMemcpyDeviceToHost);
            if (err != cudaSuccess) return err;
            if (best != ULLONG_MAX) { nonce = best; break; }
            if (start > UINT64_MAX - chunk) return cudaErrorInvalidValue;
            start += chunk;
        }
    }

    uint8_t nonce_bytes[8];
    le64(nonce_bytes, nonce);
    challenger.observe_bytes(nonce_bytes, sizeof(nonce_bytes));
    return cudaSuccess;
}
