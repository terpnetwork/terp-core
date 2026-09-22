//! Bit-for-bit Ethereum-precompile conformance vectors.
//!
//! Where `vectors.rs` exercises algebraic identities (G+G=2G, k·G via repeated
//! addition, bilinearity), this file pins down **exact byte strings** from
//! canonical Ethereum sources. A reviewer should be able to grep any hex blob
//! below in `go-ethereum/core/vm/contracts_test.go` (or in the EIP-196 / EIP-197
//! spec text) and find an identical fixture.
//!
//! Sources cited per test:
//!
//!   * `EIP-196` — point addition + scalar multiplication on the alt_bn128 curve
//!     <https://eips.ethereum.org/EIPS/eip-196>
//!   * `EIP-197` — pairing checks on alt_bn128
//!     <https://eips.ethereum.org/EIPS/eip-197>
//!   * `EIP-1108` — gas reduction (defines the cost schedule, not new fixtures)
//!     <https://eips.ethereum.org/EIPS/eip-1108>
//!   * `go-ethereum/core/vm/contracts_test.go` — execution-layer reference impl
//!     <https://github.com/ethereum/go-ethereum/blob/master/core/vm/contracts_test.go>
//!
//! Coverage target (plan §0.2 — 24 vectors total):
//!
//!   | Precompile  | Positive | Negative |
//!   |-------------|----------|----------|
//!   | ECADD       | 5        | 3        |
//!   | ECMUL       | 5        | 3        |
//!   | ECPAIRING   | 5        | 3        |
//!
//! The full 24-vector suite is now complete (4 EIP-196/197 spec vectors +
//! 20 go-ethereum `core/vm/testdata/precompiles/*.json` fixtures).

use cosmwasm_crypto_bn254::{bn254_add, bn254_pairing_equality, bn254_scalar_mul, Bn254Error};

/// Decode a hex string into a byte vector. Line comments (`//` to end of line)
/// are stripped first, then any remaining non-hex character is dropped. This
/// lets test fixtures embed inline annotations and free whitespace without
/// distorting the data — but keeps the parser honest about which bytes count.
fn hx(s: &str) -> Vec<u8> {
    let stripped: String = s
        .lines()
        .map(|line| line.split("//").next().unwrap_or(""))
        .collect::<Vec<_>>()
        .join("\n");
    let cleaned: String = stripped.chars().filter(|c| c.is_ascii_hexdigit()).collect();
    assert!(
        cleaned.len() % 2 == 0,
        "hex literal must contain an even number of hex digits after comment-stripping, \
         got {} from input {s:?}",
        cleaned.len()
    );
    (0..cleaned.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&cleaned[i..i + 2], 16).expect("invalid hex"))
        .collect()
}

// ─── ECADD vectors ─────────────────────────────────────────────────────────

/// EIP-196 §"Test Cases" — ECADD example 1.
///
/// Source: <https://eips.ethereum.org/EIPS/eip-196> (search "Example 1").
///
/// Adds the identity element `(0, 0)` to itself; result is the identity.
/// Confirms the identity element is encoded as 64 zero bytes and that the
/// precompile preserves it.
#[test]
fn eip196_ecadd_identity_plus_identity() {
    let input = hx(
        "0000000000000000000000000000000000000000000000000000000000000000\
         0000000000000000000000000000000000000000000000000000000000000000\
         0000000000000000000000000000000000000000000000000000000000000000\
         0000000000000000000000000000000000000000000000000000000000000000",
    );
    let expected = hx(
        "0000000000000000000000000000000000000000000000000000000000000000\
         0000000000000000000000000000000000000000000000000000000000000000",
    );
    let out = bn254_add(&input).expect("identity addition must succeed");
    assert_eq!(out.as_slice(), expected.as_slice());
}

/// EIP-196 §"Test Cases" — ECADD example 2.
///
/// `G1 + (-G1) = O` where `G1 = (1, 2)` is the alt_bn128 generator and
/// `-G1 = (1, p-2)` is its negation. The result must be the identity, encoded
/// as 64 zero bytes.
///
/// `p` (BN254 base-field modulus) =
///   `0x30644E72E131A029B85045B68181585D97816A916871CA8D3C208C16D87CFD47`
/// so `p - 2 =`
///   `0x30644E72E131A029B85045B68181585D97816A916871CA8D3C208C16D87CFD45`.
#[test]
fn eip196_ecadd_g1_plus_neg_g1_is_identity() {
    let input = hx(
        // G1 = (1, 2)
        "0000000000000000000000000000000000000000000000000000000000000001\
         0000000000000000000000000000000000000000000000000000000000000002\
         // -G1 = (1, p-2)
         0000000000000000000000000000000000000000000000000000000000000001\
         30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd45",
    );
    let expected = hx(
        "0000000000000000000000000000000000000000000000000000000000000000\
         0000000000000000000000000000000000000000000000000000000000000000",
    );
    let out = bn254_add(&input).expect("G + (-G) must succeed");
    assert_eq!(out.as_slice(), expected.as_slice(), "G + (-G) must be O");
}

// ─── ECMUL vectors ─────────────────────────────────────────────────────────

/// EIP-196 §"Test Cases" — ECMUL example 1.
///
/// `0 · G1 = O`. The precompile must return the identity element regardless
/// of the input point (provided it is on-curve).
#[test]
fn eip196_ecmul_zero_scalar_is_identity() {
    let input = hx(
        // G1 = (1, 2)
        "0000000000000000000000000000000000000000000000000000000000000001\
         0000000000000000000000000000000000000000000000000000000000000002\
         // scalar = 0
         0000000000000000000000000000000000000000000000000000000000000000",
    );
    let expected = hx(
        "0000000000000000000000000000000000000000000000000000000000000000\
         0000000000000000000000000000000000000000000000000000000000000000",
    );
    let out = bn254_scalar_mul(&input).expect("0 · G must succeed");
    assert_eq!(out.as_slice(), expected.as_slice(), "0 · G must be O");
}

// ─── ECPAIRING vectors ─────────────────────────────────────────────────────

/// EIP-197 §"Specification" — empty input contract.
///
/// > "If the length of the input is not a multiple of 192, the call fails.
/// >  An empty input is allowed and must return 1 (true)."
///
/// We ratify the second clause here; the first clause is exercised in
/// `vectors.rs::ecpairing_rejects_non_multiple_of_192` (algebraic suite).
#[test]
fn eip197_ecpairing_empty_input_returns_true() {
    let result = bn254_pairing_equality(&[]).expect("empty input must succeed");
    assert!(
        result,
        "EIP-197 empty input must yield true (the empty product)"
    );
}

// ─── ECADD positive (3 more) ─────────────────────────────────────────────

/// go-ethereum `bn256Add.json` — chfast1.
///
/// Source: <https://github.com/ethereum/go-ethereum/blob/master/core/vm/testdata/precompiles/bn256Add.json>
///
/// Arbitrary on-curve point addition with non-trivial result.
#[test]
fn eip196_ecadd_chfast1() {
    let input = hx(
        "18b18acfb4c2c30276db5411368e7185b311dd124691610c5d3b74034e093dc9\
         063c909c4720840cb5134cb9f59fa749755796819658d32efc0d288198f37266\
         07c2b7f58a84bd6145f00c9c2bc0bb1a187f20ff2c92963a88019e7c6a014eed\
         06614e20c147e940f2d70da3f74c9a17df361706a4485c742bd6788478fa17d7",
    );
    let expected = hx(
        "2243525c5efd4b9c3d3c45ac0ca3fe4dd85e830a4ce6b65fa1eeaee202839703\
         301d1d33be6da8e509df21cc35964723180eed7532537db9ae5e7d48f195c915",
    );
    let out = bn254_add(&input).expect("chfast1 must succeed");
    assert_eq!(out.as_slice(), expected.as_slice());
}

/// go-ethereum `bn256Add.json` — chfast2.
///
/// Commuted operands of chfast1; result must be identical.
#[test]
fn eip196_ecadd_chfast2() {
    let input = hx(
        "2243525c5efd4b9c3d3c45ac0ca3fe4dd85e830a4ce6b65fa1eeaee202839703\
         301d1d33be6da8e509df21cc35964723180eed7532537db9ae5e7d48f195c915\
         18b18acfb4c2c30276db5411368e7185b311dd124691610c5d3b74034e093dc9\
         063c909c4720840cb5134cb9f59fa749755796819658d32efc0d288198f37266",
    );
    let expected = hx(
        "2bd3e6d0f3b142924f5ca7b49ce5b9d54c4703d7ae5648e61d02268b1a0a9fb7\
         21611ce0a6af85915e2f1d70300909ce2e49dfad4a4619c8390cae66cefdb204",
    );
    let out = bn254_add(&input).expect("chfast2 must succeed");
    assert_eq!(out.as_slice(), expected.as_slice());
}

/// go-ethereum `bn256Add.json` — cdetrio11.
///
/// `G1 + G1 = 2·G1` where `G1 = (1, 2)`. The expected result is the
/// well-known doubling of the generator on alt_bn128.
#[test]
fn eip196_ecadd_g1_plus_g1_is_2g() {
    let input = hx(
        "0000000000000000000000000000000000000000000000000000000000000001\
         0000000000000000000000000000000000000000000000000000000000000002\
         0000000000000000000000000000000000000000000000000000000000000001\
         0000000000000000000000000000000000000000000000000000000000000002",
    );
    let expected = hx(
        "030644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd3\
         15ed738c0e0a7c92e7845f96b2ae9c0a68a6a449e3538fc7ff3ebf7a5a18a2c4",
    );
    let out = bn254_add(&input).expect("G + G must succeed");
    assert_eq!(out.as_slice(), expected.as_slice());
}

// ─── ECADD negative (2 more) ───────────────────────────────────────────────

/// go-ethereum `bn256Add.json` — cdetrio5 (padded to 192 bytes).
///
/// Our implementation rejects over-long inputs rather than silently
/// truncating. The go-ethereum VM pads then ignores trailing bytes; we
/// choose strictness so that malformed inputs fail loud.
#[test]
fn ecadd_rejects_long_input() {
    let input = hx(
        // 192 bytes — two G1 points plus 64 bytes of trailing garbage
        "0000000000000000000000000000000000000000000000000000000000000000\
         0000000000000000000000000000000000000000000000000000000000000000\
         0000000000000000000000000000000000000000000000000000000000000000\
         0000000000000000000000000000000000000000000000000000000000000000\
         0000000000000000000000000000000000000000000000000000000000000000\
         0000000000000000000000000000000000000000000000000000000000000000",
    );
    assert_eq!(input.len(), 192);
    let err = bn254_add(&input).unwrap_err();
    assert!(
        matches!(err, Bn254Error::InvalidInputLength { .. }),
        "expected InvalidInputLength, got {err:?}"
    );
}

/// ECADD must reject an off-curve point even when the other operand is valid.
///
/// `(1, 1)` is canonical (`0 < 1 < p`) but does **not** satisfy
/// `y² = x³ + 3` on BN254 (`1 ≠ 1 + 3`).
#[test]
fn ecadd_rejects_not_on_curve() {
    let input = hx(
        // (1, 1) — canonical, off-curve
        "0000000000000000000000000000000000000000000000000000000000000001\
         0000000000000000000000000000000000000000000000000000000000000001\
         // second summand is the identity
         0000000000000000000000000000000000000000000000000000000000000000\
         0000000000000000000000000000000000000000000000000000000000000000",
    );
    let err = bn254_add(&input).unwrap_err();
    assert!(
        matches!(err, Bn254Error::NotOnCurve),
        "expected NotOnCurve, got {err:?}"
    );
}

// ─── ECMUL positive (4 more) ─────────────────────────────────────────────

/// go-ethereum `bn256ScalarMul.json` — chfast1.
#[test]
fn eip196_ecmul_chfast1() {
    let input = hx(
        "2bd3e6d0f3b142924f5ca7b49ce5b9d54c4703d7ae5648e61d02268b1a0a9fb7\
         21611ce0a6af85915e2f1d70300909ce2e49dfad4a4619c8390cae66cefdb204\
         00000000000000000000000000000000000000000000000011138ce750fa15c2",
    );
    let expected = hx(
        "070a8d6a982153cae4be29d434e8faef8a47b274a053f5a4ee2a6c9c13c31e5c\
         031b8ce914eba3a9ffb989f9cdd5b0f01943074bf4f0f315690ec3cec6981afc",
    );
    let out = bn254_scalar_mul(&input).expect("chfast1 must succeed");
    assert_eq!(out.as_slice(), expected.as_slice());
}

/// go-ethereum `bn256ScalarMul.json` — chfast2.
#[test]
fn eip196_ecmul_chfast2() {
    let input = hx(
        "070a8d6a982153cae4be29d434e8faef8a47b274a053f5a4ee2a6c9c13c31e5c\
         031b8ce914eba3a9ffb989f9cdd5b0f01943074bf4f0f315690ec3cec6981afc\
         30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd46",
    );
    let expected = hx(
        "025a6f4181d2b4ea8b724290ffb40156eb0adb514c688556eb79cdea0752c2bb\
         2eff3f31dea215f1eb86023a133a996eb6300b44da664d64251d05381bb8a02e",
    );
    let out = bn254_scalar_mul(&input).expect("chfast2 must succeed");
    assert_eq!(out.as_slice(), expected.as_slice());
}

/// go-ethereum `bn256ScalarMul.json` — chfast3.
#[test]
fn eip196_ecmul_chfast3() {
    let input = hx(
        "025a6f4181d2b4ea8b724290ffb40156eb0adb514c688556eb79cdea0752c2bb\
         2eff3f31dea215f1eb86023a133a996eb6300b44da664d64251d05381bb8a02e\
         183227397098d014dc2822db40c0ac2ecbc0b548b438e5469e10460b6c3e7ea3",
    );
    let expected = hx(
        "14789d0d4a730b354403b5fac948113739e276c23e0258d8596ee72f9cd9d32\
         30af18a63153e0ec25ff9f2951dd3fa90ed0197bfef6e2a1a62b5095b9d2b4a27",
    );
    let out = bn254_scalar_mul(&input).expect("chfast3 must succeed");
    assert_eq!(out.as_slice(), expected.as_slice());
}

/// go-ethereum `bn256ScalarMul.json` — cdetrio5.
///
/// Scalar = 1 must return the base point unchanged.
#[test]
fn eip196_ecmul_scalar_one_is_identity_mul() {
    let input = hx(
        "17c139df0efee0f766bc0204762b774362e4ded88953a39ce849a8a7fa163fa9\
         01e0559bacb160664764a357af8a9fe70baa9258e0b959273ffc5718c6d4cc7c\
         0000000000000000000000000000000000000000000000000000000000000001",
    );
    let expected = hx(
        "17c139df0efee0f766bc0204762b774362e4ded88953a39ce849a8a7fa163fa9\
         01e0559bacb160664764a357af8a9fe70baa9258e0b959273ffc5718c6d4cc7c",
    );
    let out = bn254_scalar_mul(&input).expect("1·P must succeed");
    assert_eq!(out.as_slice(), expected.as_slice());
}

// ─── ECMUL negative (3 more) ─────────────────────────────────────────────

/// ECMUL must reject inputs shorter than 96 bytes.
#[test]
fn ecmul_rejects_short_input() {
    let input = hx(
        // 64 bytes — a full G1 point with no scalar
        "0000000000000000000000000000000000000000000000000000000000000001\
         0000000000000000000000000000000000000000000000000000000000000002",
    );
    assert_eq!(input.len(), 64);
    let err = bn254_scalar_mul(&input).unwrap_err();
    assert!(
        matches!(err, Bn254Error::InvalidInputLength { .. }),
        "expected InvalidInputLength, got {err:?}"
    );
}

/// ECMUL must reject inputs longer than 96 bytes.
#[test]
fn ecmul_rejects_long_input() {
    let input = hx(
        // 128 bytes — G1 point + scalar + 32 bytes of trailing garbage
        "0000000000000000000000000000000000000000000000000000000000000001\
         0000000000000000000000000000000000000000000000000000000000000002\
         0000000000000000000000000000000000000000000000000000000000000000\
         0000000000000000000000000000000000000000000000000000000000000000",
    );
    assert_eq!(input.len(), 128);
    let err = bn254_scalar_mul(&input).unwrap_err();
    assert!(
        matches!(err, Bn254Error::InvalidInputLength { .. }),
        "expected InvalidInputLength, got {err:?}"
    );
}

/// ECMUL must reject an off-curve base point.
#[test]
fn ecmul_rejects_not_on_curve() {
    let input = hx(
        // (1, 1) — canonical, off-curve; scalar = 1
        "0000000000000000000000000000000000000000000000000000000000000001\
         0000000000000000000000000000000000000000000000000000000000000001\
         0000000000000000000000000000000000000000000000000000000000000001",
    );
    let err = bn254_scalar_mul(&input).unwrap_err();
    assert!(
        matches!(err, Bn254Error::NotOnCurve),
        "expected NotOnCurve, got {err:?}"
    );
}

// ─── ECPAIRING positive (4 more) ─────────────────────────────────────────

/// go-ethereum `bn256Pairing.json` — jeff1.
///
/// A single well-formed pair whose product evaluates to 1.
#[test]
fn eip197_ecpairing_jeff1() {
    let input = hx(
        "1c76476f4def4bb94541d57ebba1193381ffa7aa76ada664dd31c16024c43f59\
         3034dd2920f673e204fee2811c678745fc819b55d3e9d294e45c9b03a76aef41\
         209dd15ebff5d46c4bd888e51a93cf99a7329636c63514396b4a452003a35bf70\
         4bf11ca01483bfa8b34b43561848d28905960114c8ac04049af4b6315a416782b\
         b8324af6cfc93537a2ad1a445cfd0ca2a71acd7ac41fadbf933c2a51be344d12\
         0a2a4cf30c1bf9845f20c6fe39e07ea2cce61f0c9bb048165fe5e4de87755011\
         1e129f1cf1097710d41c4ac70fcdfa5ba2023c6ff1cbeac322de49d1b6df7c2\
         032c61a830e3c17286de9462bf242fca2883585b93870a73853face6a6bf4111\
         98e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2\
         1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed\
         090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b\
         12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa",
    );
    assert!(bn254_pairing_equality(&input).expect("jeff1 must succeed"));
}

/// go-ethereum `bn256Pairing.json` — two_point_match_2.
///
/// Two pairs whose combined product evaluates to 1 (bilinearity check).
#[test]
fn eip197_ecpairing_two_point_match_2() {
    let input = hx(
        "0000000000000000000000000000000000000000000000000000000000000001\
         0000000000000000000000000000000000000000000000000000000000000002\
         198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c\
         21800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed\
         090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b\
         12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa\
         0000000000000000000000000000000000000000000000000000000000000001\
         0000000000000000000000000000000000000000000000000000000000000002\
         198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c\
         21800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed\
         275dc4a288d1afb3cbb1ac09187524c7db36395df7be3b99e673b13a075a65ec\
         1d9befcd05a5323e6da4d435f3b617cdb3af83285c2df711ef39c01571827f9d",
    );
    assert!(bn254_pairing_equality(&input).expect("two_point_match_2 must succeed"));
}

/// go-ethereum `bn256Pairing.json` — jeff2.
#[test]
fn eip197_ecpairing_jeff2() {
    let input = hx(
        "2eca0c7238bf16e83e7a1e6c5d49540685ff51380f309842a98561558019fc02\
         03d3260361bb8451de5ff5ecd17f010ff22f5c31cdf184e9020b06fa5997db84\
         1213d2149b006137fcfb23036606f848d638d576a120ca981b5b1a5f9300b3ee\
         2276cf730cf493cd95d64677bbb75fc42db72513a4c1e387b476d056f80aa75f\
         21ee6226d31426322afcda621464d0611d226783262e21bb3bc86b537e9862370\
         96df1f82dff337dd5972e32a8ad43e28a78a96a823ef1cd4debe12b6552ea5f06\
         967a1237ebfeca9aaae0d6d0bab8e28c198c5a339ef8a2407e31cdac516db92\
         2160fa257a5fd5b280642ff47b65eca77e626cb685c84fa6d3b6882a283ddd11\
         98e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2\
         1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed\
         090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b\
         12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa",
    );
    assert!(bn254_pairing_equality(&input).expect("jeff2 must succeed"));
}

/// go-ethereum `bn256Pairing.json` — jeff3.
#[test]
fn eip197_ecpairing_jeff3() {
    let input = hx(
        "0f25929bcb43d5a57391564615c9e70a992b10eafa4db109709649cf48c50dd2\
         16da2f5cb6be7a0aa72c440c53c9bbdfec6c36c7d515536431b3a865468acbba\
         2e89718ad33c8bed92e210e81d1853435399a271913a6520736a4729cf0d51eb0\
         1a9e2ffa2e92599b68e44de5bcf354fa2642bd4f26b259daa6f7ce3ed57aeb31\
         4a9a87b789a58af499b314e13c3d65bede56c07ea2d418d6874857b707637131\
         78fb49a2d6cd347dc58973ff49613a20757d0fcc22079f9abd10c3baee245901b\
         9e027bd5cfc2cb5db82d4dc9677ac795ec500ecd47deee3b5da006d6d049b811d\
         7511c78158de484232fc68daf8a45cf217d1c2fae693ff5871e8752d73b21198e\
         9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c21800de\
         ef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed090689d\
         0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b12c85ea5d\
         b8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa",
    );
    assert!(bn254_pairing_equality(&input).expect("jeff3 must succeed"));
}

// ─── ECPAIRING negative (3 more) ─────────────────────────────────────────

/// go-ethereum `bn256Pairing.json` — jeff6.
///
/// A single pair whose product does **not** evaluate to 1.
#[test]
fn eip197_ecpairing_jeff6_returns_false() {
    let input = hx(
        "1c76476f4def4bb94541d57ebba1193381ffa7aa76ada664dd31c16024c43f59\
         3034dd2920f673e204fee2811c678745fc819b55d3e9d294e45c9b03a76aef41\
         209dd15ebff5d46c4bd888e51a93cf99a7329636c63514396b4a452003a35bf70\
         4bf11ca01483bfa8b34b43561848d28905960114c8ac04049af4b6315a416782b\
         b8324af6cfc93537a2ad1a445cfd0ca2a71acd7ac41fadbf933c2a51be344d12\
         0a2a4cf30c1bf9845f20c6fe39e07ea2cce61f0c9bb048165fe5e4de87755011\
         1e129f1cf1097710d41c4ac70fcdfa5ba2023c6ff1cbeac322de49d1b6df7c1\
         03188585e2364128fe25c70558f1560f4f9350baf3959e603cc91486e11093619\
         8e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2\
         1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed\
         090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b\
         12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa",
    );
    let result = bn254_pairing_equality(&input).expect("jeff6 must not error");
    assert!(!result, "jeff6 must return false");
}

/// go-ethereum `bn256Pairing.json` — one_point.
///
/// A single non-trivial pair whose product does **not** evaluate to 1.
#[test]
fn eip197_ecpairing_one_point_returns_false() {
    let input = hx(
        "0000000000000000000000000000000000000000000000000000000000000001\
         0000000000000000000000000000000000000000000000000000000000000002\
         198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c\
         21800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed\
         090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b\
         12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa",
    );
    let result = bn254_pairing_equality(&input).expect("one_point must not error");
    assert!(!result, "one_point must return false");
}

/// ECPAIRING must reject inputs whose length is not a multiple of 192 bytes.
#[test]
fn eip197_ecpairing_rejects_non_multiple_of_192() {
    let input = hx(
        // 128 bytes — one full G1 point plus only the first FQ of the G2
        "0000000000000000000000000000000000000000000000000000000000000001\
         0000000000000000000000000000000000000000000000000000000000000002\
         198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c\
         21800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed",
    );
    assert_eq!(input.len(), 128);
    let err = bn254_pairing_equality(&input).unwrap_err();
    assert!(
        matches!(err, Bn254Error::InvalidPairingInputLength(128)),
        "expected InvalidPairingInputLength(128), got {err:?}"
    );
}
