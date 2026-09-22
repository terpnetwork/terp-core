/// Trailer length on Path A circuit blobs (not part of halo2).
pub const COSMWASM_FOOTER_LENGTH: usize = 80;

use crate::circuits::CircuitType;
use crate::curves::CurveType;
use crate::errors::{ZkError, ZkResult};

/// Circuit footer metadata - [[COSMWASM_FOOTER_LENGTH]] bytes containing complete constraint system specification.
/// V2 CS-inclusive format: enables generic deserialization via DynamicCircuit
/// without needing the original circuit type.
///
/// # Empty-param (Groth16 / BN254) convention
///
/// Proving systems without reusable Halo2-style params use:
/// - `prover_id` = [`CircuitType::Groth16`] (1)
/// - `curve_id` = 4 ([`CurveType::Bn254`]) when BN254
/// - `k` = 0 (unused)
/// - `param_len` = 0, `cs_len` = 0, `vk_len` = |vk_bytes|
/// - `param_checksum` = SHA-256 of the empty byte string (`SHA256([])`)
/// - `vk_checksum` = SHA-256 of the vk body bytes
///
/// Blob layout remains `[params | cs+vk | footer]` with a zero-length params
/// prefix. Split storage still writes an empty `zk_param/{param_key}.bin`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CircuitFooter {
    /// Circuit proving type identifier (`CircuitType`: Plonkish=0, Groth16=1)
    pub prover_id: u8,
    /// Circuit constraint system curve identifier (`CurveType`)
    pub curve_id: u8,
    /// K element in circuit constraint system (0 when unused, e.g. Groth16).
    pub k: u8,
    /// Number of public input scalars required by this circuit
    pub i: u8,
    /// Byte length of reusable params (0 for Groth16 / empty-param path)
    pub param_len: u32,
    /// byte length of constraint systems
    pub cs_len: u32,
    /// byte length of vk
    pub vk_len: u32,
    /// checksum of param file (`SHA256([])` when `param_len == 0`)
    pub param_checksum: [u8; 32],
    /// checksum of vk file
    pub vk_checksum: [u8; 32],
}

impl CircuitFooter {
    /// Merges prover_id, param_id, k, and a zero byte into a single u32 key.does not include i.
    /// Layout: [ prover_id, param_id, k, 0] (Big-Endian)
    pub fn appstate_key(&self) -> u32 {
        // Construct a 8-byte array.
        // We place the 4 fields in the lower 4 bytes.
        // this value is prefixed in the hash of file we lookup (for both param and zk), unifying storage key for the zk components param and vscs
        u32::from_be_bytes([self.prover_id, self.curve_id, self.k, 0])
    }
    // appstate_key + checksum of vk
    pub fn to_circuit_key(&self) -> [u8; 72] {
        let mut key = [0u8; 72];
        let param = self.to_param_key();
        let vk = self.to_vk_key();
        key[..36].copy_from_slice(&param);
        key[36..].copy_from_slice(&vk);
        key
    }
    // appstate_key + checksum of vk
    pub fn to_vk_key(&self) -> [u8; 36] {
        self.to_file_key(&self.vk_checksum)
    }
    // appstate_key + checksum of param
    pub fn to_param_key(&self) -> [u8; 36] {
        self.to_file_key(&self.param_checksum)
    }
    // appstate_key + checksum of vk
    pub fn vk_filename(&self) -> String {
        hex::encode(self.to_file_key(&self.vk_checksum))
    }
    // appstate_key + checksum of param
    pub fn param_filename(&self) -> String {
        hex::encode(self.to_file_key(&self.param_checksum))
    }

    // prefixes checksum with circuit identifiers
    fn to_file_key(&self, checksum: &[u8; 32]) -> [u8; 36] {
        let mut key = [0u8; 36];
        key[..4].copy_from_slice(&self.appstate_key().to_le_bytes());
        key[4..].copy_from_slice(checksum);
        key
    }
}

impl std::fmt::Display for CircuitFooter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&format!("{:#?},", self.prover_id))?;
        f.write_str(&format!("{:#?}", self.curve_id))?;
        f.write_str(&format!("{:#?}", self.k))?;
        f.write_str(&format!("{:#?}", self.i))?;
        f.write_str(&format!("{:#?}", self.param_len))?;
        f.write_str(&format!("{:#?}", self.cs_len))?;
        f.write_str(&format!("{:#?}", self.vk_len))?;
        f.write_str(&format!("{:#?}", hex::encode(self.param_checksum)))?;
        f.write_str(&format!("{:#?}", hex::encode(self.vk_checksum)))
    }
}

impl From<CircuitFooter> for [u8; COSMWASM_FOOTER_LENGTH] {
    fn from(val: CircuitFooter) -> Self {
        val.to_bytes()
    }
}

impl TryFrom<&[u8]> for CircuitFooter {
    type Error = ZkError;
    fn try_from(bytes: &[u8]) -> Result<Self, Self::Error> {
        Self::from_bytes(bytes)
    }
}

impl CircuitFooter {
    pub fn file_keys(&self) -> [[u8; 36]; 2] {
        [self.to_param_key(), self.to_vk_key()]
    }
    /// Create a new v2 circuit footer (CS-inclusive format).
    pub fn new(
        prover_id: CircuitType,
        curve_id: CurveType,
        k: u8,
        i: u8,
        param_len: u32,
        cs_len: u32,
        vk_len: u32,
        param_hash: [u8; 32],
        vk_hash: [u8; 32],
    ) -> Self {
        Self {
            prover_id: prover_id.into(),
            curve_id: curve_id.into(),
            k,
            i,
            param_len,
            cs_len,
            vk_len,
            param_checksum: param_hash,
            vk_checksum: vk_hash,
        }
    }

    /// Serialize footer to exactly [COSMWASM_FOOTER_LENGTH] bytes.
    pub fn to_bytes(&self) -> [u8; COSMWASM_FOOTER_LENGTH] {
        let mut bytes = [0u8; COSMWASM_FOOTER_LENGTH];
        bytes[0] = self.prover_id;
        bytes[1] = self.curve_id;
        bytes[2] = self.k;
        bytes[3] = self.i;
        bytes[4..8].copy_from_slice(&self.param_len.to_le_bytes());
        bytes[8..12].copy_from_slice(&self.cs_len.to_le_bytes());
        bytes[12..16].copy_from_slice(&self.vk_len.to_le_bytes());
        bytes[16..48].copy_from_slice(self.param_checksum.as_slice());
        bytes[48..COSMWASM_FOOTER_LENGTH].copy_from_slice(self.vk_checksum.as_slice());
        bytes
    }

    /// Parse footer from exactly [[COSMWASM_FOOTER_LENGTH]] bytes
    pub fn from_bytes(bytes: &[u8]) -> ZkResult<Self> {
        if bytes.len() != COSMWASM_FOOTER_LENGTH {
            return Err(ZkError::new_err(format!(
                "CircuitFooter must be exactly {} bytes, got {}",
                COSMWASM_FOOTER_LENGTH,
                bytes.len()
            )));
        }
        Ok(Self {
            prover_id: bytes[0],
            curve_id: bytes[1],
            k: bytes[2],
            i: bytes[3],
            param_len: u32::from_le_bytes(bytes[4..8].try_into()?),
            cs_len: u32::from_le_bytes(bytes[8..12].try_into()?),
            vk_len: u32::from_le_bytes(bytes[12..16].try_into()?),
            param_checksum: bytes[16..48].try_into()?,
            vk_checksum: bytes[48..80].try_into()?,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::circuits::CircuitType;
    use crate::curves::CurveType;

    #[test]
    fn file_and_circuit_keys_are_fixed_width_stack_arrays() {
        let f = CircuitFooter::new(
            CircuitType::Stwo,
            CurveType::M31,
            0,
            1,
            0,
            0,
            0,
            [0x11; 32],
            [0x22; 32],
        );
        let pk = f.to_param_key();
        let vk = f.to_vk_key();
        let ck = f.to_circuit_key();
        assert_eq!(&ck[..36], &pk);
        assert_eq!(&ck[36..], &vk);
        let again = f.to_circuit_key();
        assert_eq!(ck, again);
    }
}
