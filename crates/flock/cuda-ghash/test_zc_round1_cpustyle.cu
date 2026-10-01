// Host-only de-risk for the CPU-structured (shift-reduce + convert-table) GPU port
// of zerocheck round-1. Reads the ZCR1 golden and checks two reference computations
// against round1_ab[64]/round1_c[64]:
//   Ref A: tensor re-grouping of the canonical sum (validates the column layout
//          x = o*128 + j*8 + k: small k in bits[0,3), medium j in [3,7), outer o in [7,)).
//   Ref B: the actual optimization — level-1 F8 shift-then-reduce over the 8 small
//          dims, level-2 F128 convert-table over the 16 medium dims, one outer ghash.
// No GPU. Build: make test_zc_round1_CPU-structured ; run on zerocheck_round1_vectors.bin.
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include "f128.cuh"          // F128, u64 (host-usable struct)
#include "ntt_host.hpp"      // f128_add_hd, f128_mul_hd
#include "phi8_table.cuh"    // PHI_8_TABLE[256]

static uint32_t rd_u32(FILE* f){ uint32_t v=0; if(fread(&v,4,1,f)!=1){printf("short u32\n");exit(1);} return v; }
static F128 rd_f128(FILE* f){ u64 v[2]; if(fread(v,8,2,f)!=2){printf("short f128\n");exit(1);} return F128{v[0],v[1]}; }
static bool eqf(F128 a, F128 b){ return a.lo==b.lo && a.hi==b.hi; }

// build_eq over a list of F128 challenges (LSB-first index convention, matches the
// existing test/build_eq_host and the Rust prover).
static std::vector<F128> build_eq(const std::vector<F128>& r){
    const F128 ONE{1,0};
    std::vector<F128> t; t.reserve((size_t)1<<r.size()); t.push_back(ONE);
    for(size_t j=0;j<r.size();j++){ F128 rj=r[j], omr=f128_add_hd(ONE,rj); size_t len=(size_t)1<<j; t.resize(2*len);
        for(size_t x=0;x<len;x++){ F128 v=t[x]; t[x+len]=f128_mul_hd(v,rj); t[x]=f128_mul_hd(v,omr);} }
    return t;
}

// GF(2^8) reduce of a <=15-bit polynomial, AES poly x^8+x^4+x^3+x+1 (verbatim Rust gf8_reduce).
static uint8_t gf8_reduce(uint16_t p){
    uint16_t h = p >> 8;
    uint16_t t = (p & 0xff) ^ h ^ (h<<1) ^ (h<<3) ^ (h<<4);
    uint16_t h2 = t >> 8;
    return (uint8_t)((t & 0xff) ^ h2 ^ (h2<<1) ^ (h2<<3) ^ (h2<<4));
}
// GHASH multiply-by-gamma (gamma = 0x02): left shift by 1, reduce by 0x87.
static F128 mul_by_x(F128 z){
    u64 carry = z.hi >> 63, mask = (u64)0 - carry;
    return F128{ (z.lo<<1) ^ (0x87 & mask), (z.hi<<1) | (z.lo>>63) };
}

int main(int argc, char** argv){
    const char* path = argc>1?argv[1]:"zerocheck_round1_vectors.bin";
    FILE* f = fopen(path,"rb"); if(!f){ printf("cannot open %s\n", path); return 1; }
    if(rd_u32(f)!=0x5A435231u){ printf("bad magic\n"); return 1; }
    int m=(int)rd_u32(f), k_skip=(int)rd_u32(f), k_log=(int)rd_u32(f), useful_bits=(int)rd_u32(f);
    long long rows = 1LL << (m - k_skip);
    std::vector<F128> r(m); for(auto&v:r) v=rd_f128(f);
    std::vector<uint8_t> mcol(64*64), f8mul((size_t)256*256);
    if(fread(mcol.data(),1,mcol.size(),f)!=mcol.size()){printf("short M\n");return 1;}
    if(fread(f8mul.data(),1,f8mul.size(),f)!=f8mul.size()){printf("short f8mul\n");return 1;}
    size_t pb = (size_t)1 << (m - 3);
    std::vector<uint8_t> A(pb), B(pb), C(pb);
    if(fread(A.data(),1,pb,f)!=pb||fread(B.data(),1,pb,f)!=pb||fread(C.data(),1,pb,f)!=pb){printf("short abc\n");return 1;}
    std::vector<F128> g_ab(64), g_c(64);
    for(auto&v:g_ab) v=rd_f128(f);
    for(auto&v:g_c) v=rd_f128(f);
    fclose(f);
    printf("ZCR1: m=%d k_skip=%d rows=%lld\n", m, k_skip, rows);
    if (m < 13) { printf("need m>=13 (3 small + 4 medium + outer)\n"); return 1; }

    // eq tensor split: small = r[6..9] (3 dims), medium = r[9..13] (4 dims),
    // outer = r[13..m] (random).
    std::vector<F128> r_small(r.begin()+k_skip,        r.begin()+k_skip+3);
    std::vector<F128> r_med  (r.begin()+k_skip+3,      r.begin()+k_skip+7);
    std::vector<F128> r_out  (r.begin()+k_skip+7,      r.end());
    std::vector<F128> eq_small = build_eq(r_small);     // 8
    std::vector<F128> eq_med   = build_eq(r_med);       // 16
    std::vector<F128> eq_out   = build_eq(r_out);       // 2^(m-13)
    long long n_out = (long long)eq_out.size();
    printf("eq_small=%zu eq_med=%zu eq_out=%lld  (n_out*128 = %lld vs rows %lld)\n",
           eq_small.size(), eq_med.size(), n_out, n_out*128, rows);

    // extend: Âλ(col) = XOR_{s: bit s of column set} mcol[s*64 + λ]   (F8 byte).
    auto extend_byte = [&](const std::vector<uint8_t>& W, long long col, int lambda)->uint8_t{
        const uint8_t* colbytes = &W[(size_t)col*8];
        uint8_t acc = 0;
        for(int s=0;s<64;s++) if((colbytes[s>>3]>>(s&7))&1) acc ^= mcol[s*64 + lambda];
        return acc;
    };
    auto phi8 = [&](uint8_t v)->F128{ return PHI_8_TABLE[v]; };

    // ---- Ref A: tensor re-grouping (must equal the canonical sum exactly) ----
    {
        std::vector<F128> ab(64,F128{0,0}), cc(64,F128{0,0});
        for(long long o=0;o<n_out;o++){
            for(int lam=0; lam<64; lam++){
                F128 sab{0,0}, sc{0,0};
                for(int j=0;j<16;j++){
                    F128 jab{0,0}, jc{0,0};
                    for(int k=0;k<8;k++){
                        long long col = o*128 + j*8 + k;
                        uint8_t a=extend_byte(A,col,lam), b=extend_byte(B,col,lam), c=extend_byte(C,col,lam);
                        uint8_t ab8 = f8mul[(int)a*256+b];
                        jab = f128_add_hd(jab, f128_mul_hd(eq_small[k], phi8(ab8)));
                        jc  = f128_add_hd(jc,  f128_mul_hd(eq_small[k], phi8(c)));
                    }
                    sab = f128_add_hd(sab, f128_mul_hd(eq_med[j], jab));
                    sc  = f128_add_hd(sc,  f128_mul_hd(eq_med[j], jc));
                }
                ab[lam]=f128_add_hd(ab[lam], f128_mul_hd(eq_out[o], sab));
                cc[lam]=f128_add_hd(cc[lam], f128_mul_hd(eq_out[o], sc));
            }
        }
        int bad=0; for(int i=0;i<64;i++){ if(!eqf(ab[i],g_ab[i]))bad++; if(!eqf(cc[i],g_c[i]))bad++; }
        printf("Ref A (tensor naive):       %s (%d/128 bad)\n", bad?"FAIL":"OK", bad);
    }

    // ---- Ref B: shift-reduce (small) + convert-table (medium) + one outer ghash ----
    {
        F128 C_s = eq_small[0], C_med = eq_med[0];      // geometric leading coeffs
        F128 scale = f128_mul_hd(C_s, C_med);
        // convert[j*256 + v] = gamma^j * phi8(v)
        std::vector<F128> convert((size_t)16*256);
        F128 gpow{1,0};
        for(int j=0;j<16;j++){ for(int v=0;v<256;v++) convert[(size_t)j*256+v]=f128_mul_hd(gpow, phi8((uint8_t)v)); gpow=mul_by_x(gpow); }
        std::vector<F128> ab(64,F128{0,0}), cc(64,F128{0,0});
        for(long long o=0;o<n_out;o++){
            for(int lam=0; lam<64; lam++){
                F128 chunk_ab{0,0}, chunk_c{0,0};
                for(int j=0;j<16;j++){
                    uint16_t acc_ab=0, acc_c=0;
                    for(int k=0;k<8;k++){
                        long long col = o*128 + j*8 + k;
                        uint8_t a=extend_byte(A,col,lam), b=extend_byte(B,col,lam), c=extend_byte(C,col,lam);
                        uint8_t ab8 = f8mul[(int)a*256+b];
                        acc_ab ^= (uint16_t)ab8 << k;
                        acc_c  ^= (uint16_t)c   << k;
                    }
                    chunk_ab = f128_add_hd(chunk_ab, convert[(size_t)j*256 + gf8_reduce(acc_ab)]);
                    chunk_c  = f128_add_hd(chunk_c,  convert[(size_t)j*256 + gf8_reduce(acc_c)]);
                }
                ab[lam]=f128_add_hd(ab[lam], f128_mul_hd(eq_out[o], chunk_ab));
                cc[lam]=f128_add_hd(cc[lam], f128_mul_hd(eq_out[o], chunk_c));
            }
        }
        for(int i=0;i<64;i++){ ab[i]=f128_mul_hd(scale,ab[i]); cc[i]=f128_mul_hd(scale,cc[i]); }
        int bad=0; for(int i=0;i<64;i++){ if(!eqf(ab[i],g_ab[i]))bad++; if(!eqf(cc[i],g_c[i]))bad++; }
        printf("Ref B (shift-reduce+convert): %s (%d/128 bad)\n", bad?"FAIL":"OK", bad);
    }
    return 0;
}
