//! Penumbra Poseidon over the BLS12-377 scalar field (`poseidon377` / `decaf377::Fq`).
//!
//! Wraps `poseidon377::{hash_1,…,hash_7}` — the fixed-arity hashes used by
//! Penumbra TCT (`hash_1` / `hash_4`), asset IDs, IVK derivation, swaps, etc.

use poseidon377::{hash_1, hash_2, hash_3, hash_4, hash_5, hash_6, hash_7, Fq};

use crate::{CryptoError, CryptoResult};

/// Canonical LE encoding size for `decaf377::Fq` (BLS12-377 scalar).
pub const POSEIDON377_FIELD_BYTES: usize = 32;
/// Minimum message arity (excluding domain separator).
pub const POSEIDON377_MIN_ARITY: usize = 1;
/// Maximum message arity (Penumbra exposes hash_1…hash_7 only).
pub const POSEIDON377_MAX_ARITY: usize = 7;

fn parse_fq(bytes: &[u8; POSEIDON377_FIELD_BYTES]) -> CryptoResult<Fq> {
    Fq::from_bytes_checked(bytes).map_err(|_| CryptoError::invalid_hash_format())
}

fn fq_to_bytes(f: Fq) -> [u8; POSEIDON377_FIELD_BYTES] {
    f.to_bytes()
}

fn parse_message(inputs: &[[u8; POSEIDON377_FIELD_BYTES]]) -> CryptoResult<Vec<Fq>> {
    if !(POSEIDON377_MIN_ARITY..=POSEIDON377_MAX_ARITY).contains(&inputs.len()) {
        return Err(CryptoError::generic_err(format!(
            "poseidon377 message arity must be {POSEIDON377_MIN_ARITY}..={POSEIDON377_MAX_ARITY}, got {}",
            inputs.len()
        )));
    }
    inputs.iter().map(parse_fq).collect()
}

/// Poseidon377 hash with domain separator + `1..=7` message field elements.
///
/// This is the Penumbra host-facing API: `hash_n(domain, msg…)` for n = msg.len().
pub fn poseidon377_hash(
    domain: &[u8; POSEIDON377_FIELD_BYTES],
    message: &[[u8; POSEIDON377_FIELD_BYTES]],
) -> CryptoResult<[u8; POSEIDON377_FIELD_BYTES]> {
    let domain = parse_fq(domain)?;
    let msg = parse_message(message)?;
    let out = match msg.as_slice() {
        [a] => hash_1(&domain, *a),
        [a, b] => hash_2(&domain, (*a, *b)),
        [a, b, c] => hash_3(&domain, (*a, *b, *c)),
        [a, b, c, d] => hash_4(&domain, (*a, *b, *c, *d)),
        [a, b, c, d, e] => hash_5(&domain, (*a, *b, *c, *d, *e)),
        [a, b, c, d, e, f] => hash_6(&domain, (*a, *b, *c, *d, *e, *f)),
        [a, b, c, d, e, f, g] => hash_7(&domain, (*a, *b, *c, *d, *e, *f, *g)),
        _ => {
            return Err(CryptoError::generic_err(
                "poseidon377 internal arity mismatch",
            ))
        }
    };
    Ok(fq_to_bytes(out))
}

/// Byte-oriented form: `domain` is 32 bytes; `message` is `n*32` concatenated bytes (`n` in 1..=7).
pub fn poseidon377_hash_bytes(
    domain: &[u8],
    message: &[u8],
) -> CryptoResult<[u8; POSEIDON377_FIELD_BYTES]> {
    if domain.len() != POSEIDON377_FIELD_BYTES {
        return Err(CryptoError::generic_err(
            "poseidon377 domain must be exactly 32 bytes",
        ));
    }
    if message.is_empty() || message.len() % POSEIDON377_FIELD_BYTES != 0 {
        return Err(CryptoError::generic_err(
            "poseidon377 message must be a non-empty multiple of 32 bytes",
        ));
    }
    let mut domain_arr = [0u8; POSEIDON377_FIELD_BYTES];
    domain_arr.copy_from_slice(domain);

    let n = message.len() / POSEIDON377_FIELD_BYTES;
    let mut elems = Vec::with_capacity(n);
    for chunk in message.chunks_exact(POSEIDON377_FIELD_BYTES) {
        let mut arr = [0u8; POSEIDON377_FIELD_BYTES];
        arr.copy_from_slice(chunk);
        elems.push(arr);
    }
    poseidon377_hash(&domain_arr, &elems)
}

#[cfg(test)]
mod tests {
    use super::*;
    use core::str::FromStr;

    /// Penumbra poseidon377 spec vectors (capacity 1, domain `Penumbra_TestVec` as LE Fq).
    /// Rate n uses the first n inputs; output is the next element in the chain.
    /// Source: Penumbra Poseidon377 test vectors (BLS12-377 scalar / `decaf377::Fq`, not BLS12-381).
    const PENUMBRA_CHAIN: &[&str] = &[
        "7553885614632219548127688026174585776320152166623257619763178041781456016062",
        "2337838243217876174544784248400816541933405738836087430664765452605435675740",
        "4318449279293553393006719276941638490334729643330833590842693275258805886300",
        "2884734248868891876687246055367204388444877057000108043377667455104051576315",
        "5235431038142849831913898188189800916077016298531443239266169457588889298166",
        "66948599770858083122195578203282720327054804952637730715402418442993895152",
        "6797655301930638258044003960605211404784492298673033525596396177265014216269",
    ];

    fn fq(s: &str) -> Fq {
        Fq::from_str(s).unwrap()
    }

    fn domain() -> [u8; 32] {
        Fq::from_le_bytes_mod_order(b"Penumbra_TestVec").to_bytes()
    }

    #[test]
    fn penumbra_testvecs_rate_1_through_6() {
        let d = domain();
        for rate in 1..=6 {
            let inputs: Vec<[u8; 32]> = PENUMBRA_CHAIN[..rate]
                .iter()
                .map(|s| fq(s).to_bytes())
                .collect();
            let expected = fq(PENUMBRA_CHAIN[rate]).to_bytes();
            let out = poseidon377_hash(&d, &inputs).unwrap();
            assert_eq!(
                out, expected,
                "poseidon377 rate {rate} mismatch (want Penumbra Fq / BLS12-377)"
            );
            let mut concat = Vec::new();
            for e in &inputs {
                concat.extend_from_slice(e);
            }
            assert_eq!(poseidon377_hash_bytes(&d, &concat).unwrap(), expected);
        }
    }

    #[test]
    fn bytes_api_matches() {
        let domain_sep = Fq::from_le_bytes_mod_order(b"Penumbra_TestVec");
        let input = Fq::from_str(
            "7553885614632219548127688026174585776320152166623257619763178041781456016062",
        )
        .unwrap();
        let d = domain_sep.to_bytes();
        let m = input.to_bytes();
        let a = poseidon377_hash(&d, &[m]).unwrap();
        let b = poseidon377_hash_bytes(&d, &m).unwrap();
        assert_eq!(a, b);
    }

    #[test]
    fn rejects_bad_arity() {
        let d = [0u8; 32];
        // zero is valid Fq
        assert!(poseidon377_hash(&d, &[]).is_err());
        let eight = [[0u8; 32]; 8];
        assert!(poseidon377_hash(&d, &eight).is_err());
    }
}
