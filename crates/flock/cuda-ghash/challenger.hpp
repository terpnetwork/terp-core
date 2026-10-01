// Host-side Fiat-Shamir challenger — CUDA port of src/challenger.rs::FsChallenger
// for the GPU pcs::open / Ligerito port. Pure host C++
// (no CUDA), since the transcript is inherently sequential; the GPU drives heavy
// compute between the host-derived challenges.
//
// FsChallenger absorbs a running SHA-256 state; a challenge is squeezed as
// SHA256(state || ctr) (32 B blocks, ctr = 0,1,…) WITHOUT mutating the state.
// Framing (transcript-v2, word-aligned): every op absorbs a 16-byte header
// [op, kind, 0*6, len u64 LE] and byte payloads are zero-padded to a multiple
// of 16, so each observed F128 starts at a 16-byte boundary of the absorbed
// stream (what lets a recursion circuit replay the transcript with pure copy
// constraints). Squeezes absorb ONLY their header — the squeezed output is
// NOT re-absorbed (the header itself separates consecutive samples).
// Byte-for-byte identical to the Rust FsChallenger (SHA-256 discipline).
#pragma once
#include <cstdint>
#include <cstring>
#include <cstddef>
#include <vector>
#include <set>
#include <algorithm>

// Minimal F128 (host, no field math needed here).
struct ChF128 { uint64_t lo, hi; };
// Quadratic-extension element as its two canonical F128 coordinates.
struct ChF256 { ChF128 c0, c1; };

// ---- SHA-256 (FIPS 180-4), incremental + copyable state -------------------
struct Sha256 {
    uint32_t h[8];
    uint64_t total_len;   // bytes absorbed
    uint8_t  buf[64];
    size_t   buf_len;

    Sha256() { reset(); }
    void reset() {
        static const uint32_t IV[8] = {0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
                                       0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u};
        for (int i = 0; i < 8; i++) h[i] = IV[i];
        total_len = 0; buf_len = 0;
    }

    static uint32_t rotr(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }

    void process(const uint8_t* p) {
        static const uint32_t K[64] = {
            0x428a2f98u,0x71374491u,0xb5c0fbcfu,0xe9b5dba5u,0x3956c25bu,0x59f111f1u,0x923f82a4u,0xab1c5ed5u,
            0xd807aa98u,0x12835b01u,0x243185beu,0x550c7dc3u,0x72be5d74u,0x80deb1feu,0x9bdc06a7u,0xc19bf174u,
            0xe49b69c1u,0xefbe4786u,0x0fc19dc6u,0x240ca1ccu,0x2de92c6fu,0x4a7484aau,0x5cb0a9dcu,0x76f988dau,
            0x983e5152u,0xa831c66du,0xb00327c8u,0xbf597fc7u,0xc6e00bf3u,0xd5a79147u,0x06ca6351u,0x14292967u,
            0x27b70a85u,0x2e1b2138u,0x4d2c6dfcu,0x53380d13u,0x650a7354u,0x766a0abbu,0x81c2c92eu,0x92722c85u,
            0xa2bfe8a1u,0xa81a664bu,0xc24b8b70u,0xc76c51a3u,0xd192e819u,0xd6990624u,0xf40e3585u,0x106aa070u,
            0x19a4c116u,0x1e376c08u,0x2748774cu,0x34b0bcb5u,0x391c0cb3u,0x4ed8aa4au,0x5b9cca4fu,0x682e6ff3u,
            0x748f82eeu,0x78a5636fu,0x84c87814u,0x8cc70208u,0x90befffau,0xa4506cebu,0xbef9a3f7u,0xc67178f2u};
        uint32_t w[64];
        for (int i = 0; i < 16; i++)
            w[i] = ((uint32_t)p[4*i] << 24) | ((uint32_t)p[4*i+1] << 16) | ((uint32_t)p[4*i+2] << 8) | (uint32_t)p[4*i+3];
        for (int i = 16; i < 64; i++) {
            uint32_t s0 = rotr(w[i-15], 7) ^ rotr(w[i-15], 18) ^ (w[i-15] >> 3);
            uint32_t s1 = rotr(w[i-2], 17) ^ rotr(w[i-2], 19) ^ (w[i-2] >> 10);
            w[i] = w[i-16] + s0 + w[i-7] + s1;
        }
        uint32_t a=h[0],b=h[1],c=h[2],d=h[3],e=h[4],f=h[5],g=h[6],hh=h[7];
        for (int i = 0; i < 64; i++) {
            uint32_t S1 = rotr(e,6) ^ rotr(e,11) ^ rotr(e,25);
            uint32_t ch = (e & f) ^ (~e & g);
            uint32_t t1 = hh + S1 + ch + K[i] + w[i];
            uint32_t S0 = rotr(a,2) ^ rotr(a,13) ^ rotr(a,22);
            uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
            uint32_t t2 = S0 + maj;
            hh=g; g=f; f=e; e=d+t1; d=c; c=b; b=a; a=t1+t2;
        }
        h[0]+=a; h[1]+=b; h[2]+=c; h[3]+=d; h[4]+=e; h[5]+=f; h[6]+=g; h[7]+=hh;
    }

    void update(const uint8_t* data, size_t len) {
        total_len += len;
        while (len > 0) {
            size_t take = 64 - buf_len; if (take > len) take = len;
            memcpy(buf + buf_len, data, take);
            buf_len += take; data += take; len -= take;
            if (buf_len == 64) { process(buf); buf_len = 0; }
        }
    }

    // Finalize MUTATES this state — call on a copy if you need to keep absorbing.
    void finalize(uint8_t out[32]) {
        uint64_t bitlen = total_len * 8;
        buf[buf_len++] = 0x80;
        if (buf_len > 56) { while (buf_len < 64) buf[buf_len++] = 0; process(buf); buf_len = 0; }
        while (buf_len < 56) buf[buf_len++] = 0;
        for (int i = 0; i < 8; i++) buf[56 + i] = (uint8_t)(bitlen >> (56 - 8 * i));
        process(buf);
        for (int i = 0; i < 8; i++) {
            out[4*i]   = (uint8_t)(h[i] >> 24);
            out[4*i+1] = (uint8_t)(h[i] >> 16);
            out[4*i+2] = (uint8_t)(h[i] >> 8);
            out[4*i+3] = (uint8_t)(h[i]);
        }
    }
};

// ---- FsChallenger ---------------------------------------------------------
static const uint8_t OP_DOMAIN = 0x01, OP_LABEL = 0x02, OP_OBSERVE = 0x03,
                     OP_SQUEEZE = 0x04, OP_BYTES = 0x05;
static const uint8_t KIND_SCALAR = 0x01, KIND_SLICE = 0x02;

inline void le64(uint8_t* b, uint64_t v) { for (int i = 0; i < 8; i++) b[i] = (uint8_t)(v >> (8 * i)); }
inline uint64_t rd_le64(const uint8_t* b) { uint64_t v = 0; for (int i = 0; i < 8; i++) v |= (uint64_t)b[i] << (8 * i); return v; }

struct FsChallenger {
    Sha256 hasher;

    FsChallenger(const uint8_t* domain, size_t dlen) {
        absorb_header(OP_DOMAIN, 0, (uint64_t)dlen);
        absorb_padded(domain, dlen);
    }

    // One op's 16-byte header: [op][kind][0;6][len u64 LE]. Fixed at 16 bytes
    // (not 2 + 8) so every following F128 payload is 16-byte aligned in the
    // absorbed stream — see challenger.rs::absorb_header.
    void absorb_header(uint8_t op, uint8_t kind, uint64_t len) {
        uint8_t h[16] = {0};
        h[0] = op; h[1] = kind;
        le64(h + 8, len);
        hasher.update(h, 16);
    }
    // Byte payload zero-padded up to a multiple of 16 (true length rides in
    // the header, so the padding is unambiguous).
    void absorb_padded(const uint8_t* b, size_t n) {
        hasher.update(b, n);
        size_t rem = n % 16;
        if (rem != 0) { static const uint8_t z[16] = {0}; hasher.update(z, 16 - rem); }
    }
    void absorb_f128(ChF128 v) { uint8_t b[16]; le64(b, v.lo); le64(b + 8, v.hi); hasher.update(b, 16); }

    void observe_label(const uint8_t* l, size_t n) { absorb_header(OP_LABEL, 0, n); absorb_padded(l, n); }
    void observe_f128(ChF128 v) { absorb_header(OP_OBSERVE, KIND_SCALAR, 1); absorb_f128(v); }
    void observe_f128_slice(const ChF128* v, size_t n) {
        absorb_header(OP_OBSERVE, KIND_SLICE, n);
        for (size_t i = 0; i < n; i++) absorb_f128(v[i]);
    }
    void observe_bytes(const uint8_t* b, size_t n) { absorb_header(OP_BYTES, 0, n); absorb_padded(b, n); }

    void squeeze_into(uint8_t* out, size_t n) {
        size_t off = 0; uint64_t ctr = 0;
        while (off < n) {
            Sha256 h = hasher;          // clone the live state
            uint8_t cb[8]; le64(cb, ctr); h.update(cb, 8);
            uint8_t block[32]; h.finalize(block);
            size_t take = (n - off < 32) ? (n - off) : 32;
            memcpy(out + off, block, take);
            off += take; ctr++;
        }
    }

    // The header absorb itself advances the state, so consecutive samples
    // differ; the squeezed output is NOT re-absorbed (matches the Rust).
    ChF128 sample_f128() {
        absorb_header(OP_SQUEEZE, KIND_SCALAR, 1);
        uint8_t buf[16]; squeeze_into(buf, 16);
        return ChF128{rd_le64(buf), rd_le64(buf + 8)};
    }

    void sample_f128_vec(ChF128* out, size_t n) {
        absorb_header(OP_SQUEEZE, KIND_SLICE, n);
        if (n == 0) return;   // header-only (matches Rust: empty vec squeeze)
        std::vector<uint8_t> buf(n * 16);
        squeeze_into(buf.data(), n * 16);
        for (size_t i = 0; i < n; i++) out[i] = ChF128{rd_le64(&buf[16*i]), rd_le64(&buf[16*i+8])};
    }

    // One uniform quadratic-extension challenge = one two-word vec squeeze
    // (challenger.rs::sample_f256: sample_f128_vec(2) → F256::new(w0, w1)).
    ChF256 sample_f256() {
        ChF128 w[2];
        sample_f128_vec(w, 2);
        return ChF256{w[0], w[1]};
    }

    // Absorb an F256 as its two coordinates in (c0, c1) order — one length-2
    // slice observe (challenger.rs::observe_f256 → observe_f128_slice).
    void observe_f256(ChF256 v) {
        ChF128 w[2] = {v.c0, v.c1};
        observe_f128_slice(w, 2);
    }

    static bool has_leading_zero_bits(const uint8_t sd[32], uint64_t nonce, uint32_t bits) {
        Sha256 h; h.update(sd, 32);
        uint8_t nb[8]; le64(nb, nonce); h.update(nb, 8);
        uint8_t out[32]; h.finalize(out);
        uint32_t full = bits / 8, extra = bits % 8;
        for (uint32_t i = 0; i < full; i++) if (out[i] != 0) return false;
        if (extra > 0 && (out[full] >> (8 - extra)) != 0) return false;
        return true;
    }

    uint64_t grind_pow(uint32_t bits) {
        uint8_t sd[32]; { Sha256 h = hasher; h.finalize(sd); }   // fs_pow_state_digest
        uint64_t nonce = 0;
        if (bits != 0) { while (!has_leading_zero_bits(sd, nonce, bits)) nonce++; }
        uint8_t nb[8]; le64(nb, nonce);
        observe_bytes(nb, 8);     // absorb nonce
        return nonce;
    }

    // Fused PoW + squeeze, SHA-256 discipline: the trait-default sequence
    // grind_pow(bits) then sample (challenger.rs — the one-compression fusion
    // is the chained-BLAKE3 challenger only, which this port does not carry).
    uint64_t grind_pow_and_sample_f128(uint32_t bits, ChF128* out) {
        uint64_t nonce = grind_pow(bits);
        *out = sample_f128();
        return nonce;
    }
    uint64_t grind_pow_and_sample_f128_vec(uint32_t bits, ChF128* out, size_t n) {
        uint64_t nonce = grind_pow(bits);
        sample_f128_vec(out, n);
        return nonce;
    }

    // Port of ligerito.rs::sample_distinct_queries: keep sampling f128 challenges,
    // map lo % block_len, dedup, until `count` distinct; return sorted ascending.
    // LEGACY (pre-stratified protocol) — kept for the frozen dump-bin oracles.
    std::vector<size_t> sample_distinct_queries(size_t block_len, size_t count) {
        std::set<size_t> seen;
        std::vector<size_t> out;
        out.reserve(count);
        while (out.size() < count) {
            ChF128 v = sample_f128();
            size_t q = (size_t)(v.lo % block_len);
            if (seen.insert(q).second) out.push_back(q);
        }
        std::sort(out.begin(), out.end());
        return out;
    }
};

// ---- Stratified query schedule (src/pcs/stratified.rs) ---------------------
// A level's schedule is the binary decomposition of its query count into
// power-of-two summands (depths descending, clamped at the leaf layer):
// summand of depth c draws one query in each of the 2^c depth-c subtrees.
// The cap depth (= the absorbed commitment layer, and where every opening
// path truncates) is the top summand's depth.

// LevelSchedule::decompose(queries, log_block_len).summand_depths.
inline std::vector<uint32_t> stratified_depths(size_t queries, uint32_t log_block_len) {
    std::vector<uint32_t> out;
    size_t rem = queries;
    while (rem > 0) {
        uint32_t c = 63u - (uint32_t)__builtin_clzll((unsigned long long)rem);
        if (c > log_block_len) c = log_block_len;
        out.push_back(c);
        rem -= (size_t)1 << c;
    }
    return out;
}

inline uint32_t stratified_cap_depth(const std::vector<uint32_t>& depths) {
    return depths.empty() ? 0 : depths[0];
}

// ligerito.rs::queries_from_words — one squeezed word per query, in the
// canonical sample order (summands in schedule order, strata 0..2^c within
// each): index = (stratum << (d − c)) | (word.lo & ((1 << (d − c)) − 1)).
inline std::vector<size_t> stratified_queries_from_words(uint32_t log_block_len,
                                                         const std::vector<uint32_t>& depths,
                                                         const ChF128* words, size_t n_words) {
    std::vector<size_t> out;
    out.reserve(n_words);
    size_t w = 0;
    for (uint32_t c : depths) {
        uint32_t lo_bits = log_block_len - c;
        size_t mask = (lo_bits >= 64) ? ~(size_t)0 : (((size_t)1 << lo_bits) - 1);
        for (size_t s = 0; s < ((size_t)1 << c); s++) {
            out.push_back((s << lo_bits) | ((size_t)words[w].lo & mask));
            w++;
        }
    }
    if (w != n_words) { out.clear(); }   // caller sized the squeeze wrong
    return out;
}

// ligerito.rs::grind_and_sample_queries — fused query-phase PoW (nonce always
// absorbed, 0-bit included) + ONE vector squeeze of `count` words + mapping.
inline uint64_t grind_and_sample_stratified_queries(FsChallenger& ch, uint32_t bits,
                                                    uint32_t log_block_len, size_t count,
                                                    const std::vector<uint32_t>& depths,
                                                    std::vector<size_t>& queries_out) {
    std::vector<ChF128> words(count);
    uint64_t nonce = ch.grind_pow_and_sample_f128_vec(bits, words.data(), count);
    queries_out = stratified_queries_from_words(log_block_len, depths, words.data(), count);
    return nonce;
}
