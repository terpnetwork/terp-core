// Byte-for-byte validation of the host Merkle multi-proof port (merkle_open.hpp)
// against the real flock merkle::merkle_multi_proof, via the oracle dumped by
// src/bin/dump_merkle_open_vectors.rs (MKOP format). Pure host C++ (no CUDA).
//
// Build:  make test_merkle_open
// Run:    (repo root)  cargo run --release --bin dump_merkle_open_vectors -- cuda-ghash/merkle_open_vectors.bin 14 50
//         (cuda-ghash) ./test_merkle_open merkle_open_vectors.bin
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include "merkle_open.hpp"
#include "merkle_open_device.cuh"
#include <cuda_runtime.h>

static uint32_t rd_u32(FILE* f) { uint32_t v; if (fread(&v, 4, 1, f) != 1) { printf("short read u32\n"); exit(1); } return v; }
static uint64_t rd_u64(FILE* f) { uint64_t v; if (fread(&v, 8, 1, f) != 1) { printf("short read u64\n"); exit(1); } return v; }
static MHash rd_hash(FILE* f) { MHash h; if (fread(h.b, 1, 32, f) != 32) { printf("short read hash\n"); exit(1); } return h; }

int main(int argc, char** argv) {
    const char* path = argc > 1 ? argv[1] : "merkle_open_vectors.bin";
    FILE* f = fopen(path, "rb");
    if (!f) { printf("cannot open %s (run dump_merkle_open_vectors first)\n", path); return 1; }

    if (rd_u32(f) != 0x4D4B4F50u) { printf("bad file (want MKOP)\n"); return 1; }
    size_t num_leaves = rd_u32(f);
    uint32_t tree_len = rd_u32(f);
    std::vector<MHash> tree(tree_len);
    for (uint32_t i = 0; i < tree_len; i++) tree[i] = rd_hash(f);
    uint32_t n_positions = rd_u32(f);
    std::vector<size_t> positions(n_positions);
    for (uint32_t i = 0; i < n_positions; i++) positions[i] = (size_t)rd_u64(f);
    uint32_t proof_len = rd_u32(f);
    std::vector<MHash> gold(proof_len);
    for (uint32_t i = 0; i < proof_len; i++) gold[i] = rd_hash(f);
    fclose(f);

    printf("MKOP: num_leaves=%zu n_positions=%u proof_len=%u\n", num_leaves, n_positions, proof_len);

    std::vector<MHash> proof = merkle_multi_proof_host(tree.data(), num_leaves, positions);

    if (proof.size() != gold.size()) {
        printf("PROOF LEN FAIL: got %zu exp %u\n", proof.size(), proof_len);
        return 1;
    }
    for (size_t i = 0; i < proof.size(); i++) {
        if (!mhash_eq(proof[i], gold[i])) {
            printf("PROOF FAIL at sibling %zu: first byte got %02x exp %02x\n",
                   i, proof[i].b[0], gold[i].b[0]);
            return 1;
        }
    }

    // Device path: upload the tree, gather the emitted nodes on device, compare.
    uint8_t* d_tree; cudaMalloc(&d_tree, (size_t)tree_len * 32);
    cudaMemcpy(d_tree, tree.data(), (size_t)tree_len * 32, cudaMemcpyHostToDevice);
    std::vector<MHash> dproof = merkle_multi_proof_device(d_tree, num_leaves, positions);
    cudaFree(d_tree);
    if (dproof.size() != gold.size()) { printf("DEVICE PROOF LEN FAIL\n"); return 1; }
    for (size_t i = 0; i < dproof.size(); i++) if (!mhash_eq(dproof[i], gold[i])) { printf("DEVICE PROOF FAIL @%zu\n", i); return 1; }

    printf("MERKLE-OPEN OK: host + device multi-proof (%zu siblings for %u queries) match flock byte-for-byte\n",
           proof.size(), n_positions);
    return 0;
}
