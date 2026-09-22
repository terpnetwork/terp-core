//! RedPallas / RedJubjub (RedDSA) signature verification.
//!
//! | Scheme | Curve | Sig types | Ecosystem |
//! |--------|-------|-----------|-----------|
//! | **RedPallas** | Pallas | SpendAuth, Binding | Orchard, vote-sdk ante |
//! | **RedJubjub** | Jubjub | SpendAuth, Binding | Sapling / MASP |
//!
//! Matches vote-sdk `circuits/src/redpallas.rs` / FFI `VerifySpendAuthSig`
//! (rk 32 + sighash + sig 64).
//!
//! **CPU only** — consensus pure function of inputs. Enable with feature `redpallas`.

#![cfg(feature = "redpallas")]

use reddsa::{orchard, sapling, Signature, VerificationKey};

use crate::errors::{CryptoError, CryptoResult};

/// Compressed verification key / randomized spend-auth key length (bytes).
pub const REDPALLAS_VK_LEN: usize = 32;
/// RedDSA signature length (R ‖ s).
pub const REDPALLAS_SIGNATURE_LEN: usize = 64;
/// Maximum message / sighash length accepted by host (arbitrary message allowed by reddsa).
pub const REDPALLAS_MESSAGE_MAX_LEN: usize = 4096;

fn read_vk(public_key: &[u8]) -> CryptoResult<[u8; REDPALLAS_VK_LEN]> {
    if public_key.len() != REDPALLAS_VK_LEN {
        return Err(CryptoError::invalid_pubkey_format());
    }
    let mut arr = [0u8; REDPALLAS_VK_LEN];
    arr.copy_from_slice(public_key);
    Ok(arr)
}

fn read_sig(signature: &[u8]) -> CryptoResult<[u8; REDPALLAS_SIGNATURE_LEN]> {
    if signature.len() != REDPALLAS_SIGNATURE_LEN {
        return Err(CryptoError::invalid_signature_format());
    }
    let mut arr = [0u8; REDPALLAS_SIGNATURE_LEN];
    arr.copy_from_slice(signature);
    Ok(arr)
}

fn map_verify_result(result: Result<(), reddsa::Error>) -> CryptoResult<bool> {
    match result {
        Ok(()) => Ok(true),
        // Invalid signature / failed equation → false (same style as ed25519_verify).
        // Malformed key is surfaced as InvalidPubkeyFormat by try_from path.
        Err(reddsa::Error::InvalidSignature) => Ok(false),
        Err(reddsa::Error::MalformedSigningKey) => Err(CryptoError::invalid_pubkey_format()),
        Err(reddsa::Error::MalformedVerificationKey) => Err(CryptoError::invalid_pubkey_format()),
    }
}

// ── RedPallas (Orchard / Pallas) ───────────────────────────────────────────

/// Verify a **RedPallas SpendAuth** signature (Orchard / vote-sdk).
///
/// * `message` — signed data (typically 32-byte sighash; any length ≤ 4096).
/// * `signature` — 64-byte RedPallas signature.
/// * `public_key` — 32-byte verification key (often a randomized `rk`).
pub fn redpallas_spendauth_verify(
    message: &[u8],
    signature: &[u8],
    public_key: &[u8],
) -> CryptoResult<bool> {
    let rk = read_vk(public_key)?;
    let sig_bytes = read_sig(signature)?;
    let vk = match VerificationKey::<orchard::SpendAuth>::try_from(rk) {
        Ok(vk) => vk,
        Err(_) => return Err(CryptoError::invalid_pubkey_format()),
    };
    let sig = Signature::<orchard::SpendAuth>::from(sig_bytes);
    map_verify_result(vk.verify(message, &sig))
}

/// Verify a **RedPallas Binding** signature (Orchard binding sig).
pub fn redpallas_binding_verify(
    message: &[u8],
    signature: &[u8],
    public_key: &[u8],
) -> CryptoResult<bool> {
    let pk = read_vk(public_key)?;
    let sig_bytes = read_sig(signature)?;
    let vk = match VerificationKey::<orchard::Binding>::try_from(pk) {
        Ok(vk) => vk,
        Err(_) => return Err(CryptoError::invalid_pubkey_format()),
    };
    let sig = Signature::<orchard::Binding>::from(sig_bytes);
    map_verify_result(vk.verify(message, &sig))
}

// ── RedJubjub (Sapling / Jubjub) ───────────────────────────────────────────

/// Verify a **RedJubjub SpendAuth** signature (Sapling).
pub fn redjubjub_spendauth_verify(
    message: &[u8],
    signature: &[u8],
    public_key: &[u8],
) -> CryptoResult<bool> {
    let pk = read_vk(public_key)?;
    let sig_bytes = read_sig(signature)?;
    let vk = match VerificationKey::<sapling::SpendAuth>::try_from(pk) {
        Ok(vk) => vk,
        Err(_) => return Err(CryptoError::invalid_pubkey_format()),
    };
    let sig = Signature::<sapling::SpendAuth>::from(sig_bytes);
    map_verify_result(vk.verify(message, &sig))
}

/// Verify a **RedJubjub Binding** signature (Sapling).
pub fn redjubjub_binding_verify(
    message: &[u8],
    signature: &[u8],
    public_key: &[u8],
) -> CryptoResult<bool> {
    let pk = read_vk(public_key)?;
    let sig_bytes = read_sig(signature)?;
    let vk = match VerificationKey::<sapling::Binding>::try_from(pk) {
        Ok(vk) => vk,
        Err(_) => return Err(CryptoError::invalid_pubkey_format()),
    };
    let sig = Signature::<sapling::Binding>::from(sig_bytes);
    map_verify_result(vk.verify(message, &sig))
}

/// Alias matching vote-sdk `verify_spend_auth_sig` naming (fixed-size args).
pub fn verify_spend_auth_sig(
    rk_bytes: &[u8; REDPALLAS_VK_LEN],
    sighash: &[u8],
    sig_bytes: &[u8; REDPALLAS_SIGNATURE_LEN],
) -> CryptoResult<bool> {
    redpallas_spendauth_verify(sighash, sig_bytes, rk_bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand_core::OsRng;
    use reddsa::{orchard as reddsa_orchard, SigningKey};

    #[test]
    fn redpallas_spendauth_roundtrip() {
        let mut rng = OsRng;
        let sk = SigningKey::<reddsa_orchard::SpendAuth>::new(&mut rng);
        let vk = VerificationKey::from(&sk);
        let msg = b"terp-redpallas-test-message";
        let sig = sk.sign(&mut rng, msg);
        let vk_bytes: [u8; 32] = vk.into();
        let sig_bytes: [u8; 64] = sig.into();

        assert!(redpallas_spendauth_verify(msg, &sig_bytes, &vk_bytes).unwrap());
        assert!(!redpallas_spendauth_verify(b"other", &sig_bytes, &vk_bytes).unwrap());
    }

    #[test]
    fn redpallas_binding_roundtrip() {
        let mut rng = OsRng;
        let sk = SigningKey::<reddsa_orchard::Binding>::new(&mut rng);
        let vk = VerificationKey::from(&sk);
        let msg = [7u8; 32];
        let sig = sk.sign(&mut rng, &msg);
        let vk_bytes: [u8; 32] = vk.into();
        let sig_bytes: [u8; 64] = sig.into();

        assert!(redpallas_binding_verify(&msg, &sig_bytes, &vk_bytes).unwrap());
    }

    #[test]
    fn redjubjub_spendauth_roundtrip() {
        let mut rng = OsRng;
        let sk = SigningKey::<sapling::SpendAuth>::new(&mut rng);
        let vk = VerificationKey::from(&sk);
        let msg = b"sapling-redjubjub";
        let sig = sk.sign(&mut rng, msg);
        let vk_bytes: [u8; 32] = vk.into();
        let sig_bytes: [u8; 64] = sig.into();

        assert!(redjubjub_spendauth_verify(msg, &sig_bytes, &vk_bytes).unwrap());
    }

    #[test]
    fn bad_lengths() {
        assert!(redpallas_spendauth_verify(b"m", &[0u8; 63], &[0u8; 32]).is_err());
        assert!(redpallas_spendauth_verify(b"m", &[0u8; 64], &[0u8; 31]).is_err());
    }

    #[test]
    fn vote_sdk_alias() {
        let mut rng = OsRng;
        let sk = SigningKey::<reddsa_orchard::SpendAuth>::new(&mut rng);
        let vk = VerificationKey::from(&sk);
        let msg = [1u8; 32];
        let sig = sk.sign(&mut rng, &msg);
        let rk: [u8; 32] = vk.into();
        let sig_b: [u8; 64] = sig.into();
        assert!(verify_spend_auth_sig(&rk, &msg, &sig_b).unwrap());
    }
}
