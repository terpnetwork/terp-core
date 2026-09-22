use cosmwasm_std::Checksum;

// keys.rs
pub const VK_PARAM_KEY_PREFIX: &[u8] = b"\x12";
pub const VK_KEY_PREFIX: &[u8] = b"\x13";
pub const CIRCUIT_KEY_PREFIX: &[u8] = b"\x16";

pub fn get_vk_param_key(param_id: u64) -> Vec<u8> {
    let mut k = VK_PARAM_KEY_PREFIX.to_vec();
    k.extend_from_slice(&param_id.to_be_bytes());
    k
}

pub fn get_vk_key(vk_id: u64) -> Vec<u8> {
    let mut k = VK_KEY_PREFIX.to_vec();
    k.extend_from_slice(&vk_id.to_be_bytes());
    k
}

pub fn get_circuit_key(zk_id: u64) -> Vec<u8> {
    let mut k = CIRCUIT_KEY_PREFIX.to_vec();
    k.extend_from_slice(&zk_id.to_be_bytes());
    k
}

pub use zk_cosmwasm::*;

use crate::COSMWASM_FOOTER_LENGTH;

/// Serializes SerializedCircuitData into a complete binary format for FFI transmission.
pub fn serialize_circuit_data(vk_data: &SerializedCircuitData) -> Vec<u8> {
    let mut result = Vec::new();
    result.extend_from_slice(&vk_data.body);
    result.extend_from_slice(&vk_data.footer);
    result
}

/// Deserializes circuit data from the FFI binary format back into SerializedCircuitData
pub fn deserialize_circuit_data(data: &[u8]) -> ZkResult<SerializedCircuitData> {
    let length = data.len();
    if length < COSMWASM_FOOTER_LENGTH {
        return Err(ZkError::new_err("Circuit data too short"));
    }
    let circuit_len = length - COSMWASM_FOOTER_LENGTH;
    Ok(SerializedCircuitData::new(
        &data[0..circuit_len],
        &data[circuit_len..],
    ))
}

/// Integrity-check a store blob.
///
/// Last 80 bytes are always CosmWasm `CircuitFooter`. `curve_id` routes later
/// (`0` Pasta IPA, `4` Groth16 BN254, `6` Halo2-axiom KZG BN256). This function
/// does not deserialize params — it only checks lengths + SHA-256 checksums.
pub fn check_circuit(bytes: &[u8]) -> ZkResult<CircuitFooter> {
    let total_len = bytes.len();
    if total_len < COSMWASM_FOOTER_LENGTH {
        return Err(ZkError::new_err(format!(
            "vm::zk::bad circuit size::length::{}",
            total_len
        )));
    };
    let footer_bytes = &bytes[total_len - COSMWASM_FOOTER_LENGTH..];
    let footer = CircuitFooter::from_bytes(footer_bytes)
        .map_err(|e| ZkError::new_err(format!("Failed to parse CircuitFooter: {}", e)))?;

    let param_len = footer.param_len as usize;
    let vk_body_end = total_len - COSMWASM_FOOTER_LENGTH;

    // C-05: total integrity — never panic on untrusted param_len.
    if param_len > vk_body_end {
        return Err(ZkError::format_err(format!(
            "param_len {} exceeds circuit body length {}",
            param_len, vk_body_end
        )));
    }

    // Split body into param bytes and vk+cs bytes (cs+vk combined for checksum).
    let param_bytes = &bytes[..param_len];
    let vk_body_bytes = &bytes[param_len..vk_body_end];

    // H-05: bind layout metadata — cs_len + vk_len must describe the vk_body.
    // (Still not in circuit_key; enforced at integrity time so bad metadata fails closed.)
    let declared_vk_body = (footer.cs_len as usize).saturating_add(footer.vk_len as usize);
    if declared_vk_body != vk_body_bytes.len() {
        // Allow legacy zero layout fields only when both are zero (unknown layout).
        if footer.cs_len != 0 || footer.vk_len != 0 {
            return Err(ZkError::format_err(format!(
                "cs_len+vk_len {} != vk_body length {}",
                declared_vk_body,
                vk_body_bytes.len()
            )));
        }
    }

    let computed_param = Checksum::generate(param_bytes);
    let computed_vk = Checksum::generate(vk_body_bytes);

    match (
        computed_param.as_slice() == footer.param_checksum,
        computed_vk.as_slice() == footer.vk_checksum,
    ) {
        (true, true) => Ok(footer),
        (false, _) => {
            tracing::error!(
                "param checksum mismatch: computed={}, expected={}",
                hex::encode(computed_param.as_slice()),
                hex::encode(footer.param_checksum)
            );
            Err(ZkError::IntegrityErr {})
        }
        (_, false) => {
            tracing::error!(
                "vk checksum mismatch: computed={}, expected={}",
                hex::encode(computed_vk.as_slice()),
                hex::encode(footer.vk_checksum)
            );
            Err(ZkError::IntegrityErr {})
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_validate_empty() {
        assert!(check_circuit(&[]).is_err());
    }

    #[test]
    fn test_validate_truncated() {
        // Just a version byte, nothing else
        assert!(check_circuit(&[0x01]).is_err());
    }

    #[test]
    fn circuit_type_conversion() {
        assert_eq!(CircuitType::try_from(0).unwrap(), CircuitType::Plonkish);
        assert_eq!(CircuitType::try_from(1).unwrap(), CircuitType::Groth16);
        assert!(CircuitType::try_from(255).is_err());
        assert_eq!(CircuitType::from_u8(1), Some(CircuitType::Groth16));
        assert_eq!(CircuitType::from_u8(99), None);
    }

    #[test]
    fn validate_empty_vk_bytes() {
        let result = check_circuit(&[]);
        println!("{:#?}", result);
        assert!(result.is_err());
        // New 32-byte footer format requires at least 32 bytes
        assert!(result.unwrap_err().to_string().contains("bad circuit size"));
    }

    /// C-05: oversized param_len must error, not panic.
    #[test]
    fn check_circuit_param_len_oob_is_err() {
        let mut blob = vec![0u8; COSMWASM_FOOTER_LENGTH + 8];
        // param_len = 0xffff_ffff LE at footer offset 4
        let footer_start = 8;
        blob[footer_start + 4..footer_start + 8].copy_from_slice(&u32::MAX.to_le_bytes());
        // minimal non-panic footer parse: rest zeros
        let err = check_circuit(&blob).unwrap_err();
        let s = err.to_string();
        assert!(
            s.contains("param_len") || s.contains("Integrity") || s.contains("format"),
            "unexpected err: {s}"
        );
    }

    #[test]
    fn check_circuit_accepts_kzg_style_footer() {
        use sha2::{Digest, Sha256};
        let params = vec![7u8; 64];
        let vk_body = vec![9u8; 32];
        let mut footer = [0u8; COSMWASM_FOOTER_LENGTH];
        footer[0] = 0; // Plonkish
        footer[1] = 6; // Bn256Kzg
        footer[2] = 17;
        footer[3] = 4;
        footer[4..8].copy_from_slice(&(params.len() as u32).to_le_bytes());
        footer[8..12].copy_from_slice(&0u32.to_le_bytes());
        footer[12..16].copy_from_slice(&(vk_body.len() as u32).to_le_bytes());
        let ph = Sha256::digest(&params);
        let vh = Sha256::digest(&vk_body);
        footer[16..48].copy_from_slice(&ph);
        footer[48..80].copy_from_slice(&vh);
        let mut blob = params;
        blob.extend_from_slice(&vk_body);
        blob.extend_from_slice(&footer);
        let f = check_circuit(&blob).expect("kzg footer");
        assert_eq!(f.curve_id, 6);
        assert_eq!(f.k, 17);
        assert_eq!(f.i, 4);
    }

    /// Helper to create a minimal valid WASM module with a custom section
    fn create_wasm_with_custom_section(section_name: &str, section_data: &[u8]) -> Vec<u8> {
        use wasm_encoder::{CustomSection, Module};

        let mut module = Module::new();

        // Add custom section
        let custom = CustomSection {
            name: std::borrow::Cow::Borrowed(section_name),
            data: std::borrow::Cow::Borrowed(section_data),
        };
        module.section(&custom);

        module.finish()
    }
}
