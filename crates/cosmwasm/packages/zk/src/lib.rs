//! Zk-CosmWasm: zk-struct specific for interacting with zk-circuit binaries
pub mod backend;
pub mod circuits;
pub mod curves;
pub mod footer;

pub mod errors;
pub use errors::{ZkError, ZkResult};

/// Placeholder: real Stwo/Flock hosts live in `zk-cosmwasm-hosts` (libwasmvm).
/// This is a no-op so guest wasm32 and the CosmWasm workspace stay free of `stwo`.
pub fn install_path_a_hosts() {}

pub use {
    backend::{select_backend, CpuBackend, SelectedBackend, VerifierBackend, VerifyItem},
    circuits::{
        AnyInstance, AnyVerifyingKey, CircuitType, CosmwasmCircuit, Proof, SerializedCircuitData,
    },
    curves::{
        prove_flock, verify_flock_proof, StwoInstance, StwoVerifyingKey, ZkCurve,
        FLOCK_HOST_VERIFY, STWO_HOST_VERIFY,
    },
    footer::{CircuitFooter, COSMWASM_FOOTER_LENGTH},
};

#[cfg(feature = "gpu")]
pub use backend::{probe_gpu, GpuBackend, GpuProbeReport, GpuProbeStatus};

#[cfg(feature = "bn254")]
pub use curves::snarkjs;
#[cfg(feature = "bn254")]
pub use curves::{
    build_bn254_circuit_blob, convert_snarkjs_proof_json, convert_snarkjs_public_json,
    convert_snarkjs_vkey_json, encode_public_inputs_be, serialize_ark_proof, serialize_ark_vk,
    verify_snarkjs_fixtures, Bn254Instance, Bn254Scalar, Bn254VerifyingKey,
};

pub(crate) use circuits::{
    CsBlueprint, CsBlueprintGuard, CwInstance, CwProvingKey, CwVerifyingKey,
};

// Key prefixes (must match Go exactly)
// TODO: terrible fragile hack, must define some sort of enum for prefix keep aligned, OR have some sort of ffi test to ensure lined up with latest key verison
pub const VK_PARAM_KEY_PREFIX: &[u8] = b"\x12";
pub const VK_KEY_PREFIX: &[u8] = b"\x13";
pub const CIRCUIT_KEY_PREFIX: &[u8] = b"\x16";
pub const CIRCUIT_INFO_KEY_PREFIX: &[u8] = b"\x16";
pub const KEY_SEQUENCE_CIRCUIT_ID: &[u8] = b"lastPlonkishCircuit";
