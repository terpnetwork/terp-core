// Bit-for-bit validation of the CUDA Merkle tree (P3) against the flare oracle.
// Feeds the GOLDEN post-NTT codeword from the CMT1 file into the Merkle kernels
// and checks the device root against the golden root — isolating P3 from P2.
//
// Build:  make test_commit_merkle
// Run:    ./test_commit_merkle commit_vectors.bin
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include "merkle.cuh"

#define CK(x) do { cudaError_t e=(x); if(e){ \
    printf("CUDA error %s at %s:%d\n", cudaGetErrorString(e), __FILE__, __LINE__); \
    exit(1);} } while(0)

static uint32_t rd_u32(FILE* f) {
    uint32_t v = 0;
    if (fread(&v, 4, 1, f) != 1) { printf("short read (u32)\n"); exit(1); }
    return v;
}

int main(int argc, char** argv) {
    const char* path = argc > 1 ? argv[1] : "commit_vectors.bin";
    FILE* f = fopen(path, "rb");
    if (!f) { printf("cannot open %s\n", path); return 1; }

    if (rd_u32(f) != 0x434D5431u) { printf("bad file (want CMT1)\n"); return 1; }
    uint32_t m = rd_u32(f), log_inv_rate = rd_u32(f), log_batch_size = rd_u32(f);
    uint32_t k_code = rd_u32(f), num_ntts = rd_u32(f), n_positions = rd_u32(f);
    uint32_t n_leaves = rd_u32(f), leaf_size_bytes = rd_u32(f), msg_len = rd_u32(f);
    (void)m; (void)log_inv_rate; (void)k_code; (void)n_positions;

    // Skip the message (we only need the golden codeword + root for P3).
    if (fseek(f, (long)msg_len * 16, SEEK_CUR) != 0) { printf("seek failed\n"); return 1; }
    uint32_t cw_len = rd_u32(f);
    std::vector<uint8_t> cw((size_t)cw_len * 16);
    if (fread(cw.data(), 1, cw.size(), f) != cw.size()) { printf("short read (codeword)\n"); return 1; }
    Hash golden_root;
    if (fread(golden_root, 1, 32, f) != 32) { printf("short read (root)\n"); return 1; }
    fclose(f);

    printf("CMT1: batch=%u num_ntts=%u n_leaves=%u leaf=%u bytes  codeword=%u F128\n",
           log_batch_size, num_ntts, n_leaves, leaf_size_bytes, cw_len);

    uint8_t *d_data = nullptr, *d_tree = nullptr;
    long long total_nodes = 2LL * n_leaves - 1;
    CK(cudaMalloc(&d_data, cw.size()));
    CK(cudaMalloc(&d_tree, total_nodes * 32));
    CK(cudaMemcpy(d_data, cw.data(), cw.size(), cudaMemcpyHostToDevice));

    int kway = argc > 2 ? atoi(argv[2]) : 1;   // 1 / 2 / 4 leaves per thread
    launch_merkle(d_data, d_tree, (long long)n_leaves, (int)leaf_size_bytes, 256, kway);
    CK(cudaGetLastError());
    CK(cudaDeviceSynchronize());

    Hash got;
    CK(cudaMemcpy(got, d_tree + (total_nodes - 1) * 32, 32, cudaMemcpyDeviceToHost));

    bool ok = true;
    for (int i = 0; i < 32; i++) if (got[i] != golden_root[i]) ok = false;
    if (!ok) {
        printf("ROOT FAIL\n  got    ");
        for (int i = 0; i < 32; i++) printf("%02x", got[i]);
        printf("\n  expect ");
        for (int i = 0; i < 32; i++) printf("%02x", golden_root[i]);
        printf("\n");
        return 1;
    }
    printf("ROOT OK: device Merkle root matches flare bit-for-bit\n");
    cudaFree(d_data); cudaFree(d_tree);
    return 0;
}
