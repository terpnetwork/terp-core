//! Import implementations

use crate::backend::{BackendApi, BackendError, Querier, Storage};
use crate::conversion::{ref_to_u32, to_u32};
use crate::environment::{process_gas_info, DebugInfo, Environment};
use crate::errors::{CommunicationError, VmError, VmResult};
#[cfg(feature = "iterator")]
use crate::memory::maybe_read_region;
use crate::memory::{read_region, write_region};
use crate::sections::decode_sections;
#[allow(unused_imports)]
use crate::sections::encode_sections;
use crate::serde::to_vec;
use crate::GasInfo;
use cosmwasm_core::{BLS12_381_G1_POINT_LEN, BLS12_381_G2_POINT_LEN};
#[cfg(feature = "bn254")]
use cosmwasm_crypto::gas;
use cosmwasm_crypto::{
    bls12_381_aggregate_g1, bls12_381_aggregate_g2, bls12_381_hash_to_g1, bls12_381_hash_to_g2,
    bls12_381_pairing_equality, ed25519_batch_verify, ed25519_verify, secp256k1_recover_pubkey,
    secp256k1_verify, secp256r1_recover_pubkey, secp256r1_verify, CryptoError, HashFunction,
};
#[cfg(feature = "bn254")]
use cosmwasm_crypto::{
    bn254_add, bn254_pairing_equality, bn254_scalar_mul, Bn254Error, G1_BYTES, G2_BYTES,
};
use cosmwasm_crypto::{
    ECDSA_PUBKEY_MAX_LEN, ECDSA_SIGNATURE_LEN, EDDSA_PUBKEY_LEN, MESSAGE_HASH_MAX_LEN,
};
#[cfg(feature = "iterator")]
use cosmwasm_std::Order;
use rand_core::OsRng;
use std::marker::PhantomData;
use wasmer::{AsStoreMut, FunctionEnvMut};

/// A kibi (kilo binary)
const KI: usize = 1024;
/// A mebi (mega binary)
const MI: usize = 1024 * 1024;
/// Max key length for db_write/db_read/db_remove/db_scan (when VM reads the key argument from Wasm memory)
const MAX_LENGTH_DB_KEY: usize = 64 * KI;
/// Max value length for db_write (when VM reads the value argument from Wasm memory)
const MAX_LENGTH_DB_VALUE: usize = 128 * KI;
/// Typically 20 (Cosmos SDK, Ethereum), 32 (Nano, Substrate) or 54 (MockApi)
const MAX_LENGTH_CANONICAL_ADDRESS: usize = 64;
/// The max length of human address inputs (in bytes).
/// The maximum allowed size for [bech32](https://github.com/bitcoin/bips/blob/master/bip-0173.mediawiki#bech32)
/// is 90 characters, and we're adding some safety margin around that for other formats.
const MAX_LENGTH_HUMAN_ADDRESS: usize = 256;
const MAX_LENGTH_QUERY_CHAIN_REQUEST: usize = 64 * KI;
/// Length of a serialized Ed25519 signature
const MAX_LENGTH_ED25519_SIGNATURE: usize = 64;
/// Max length of an Ed25519 message in bytes.
/// This is an arbitrary value, for performance / memory constraints. If you need to verify larger
/// messages, let us know.
const MAX_LENGTH_ED25519_MESSAGE: usize = 128 * 1024;
/// Max number of batch Ed25519 messages / signatures / public_keys.
/// This is an arbitrary value, for performance / memory constraints. If you need to batch-verify a
/// larger number of signatures, let us know.
const MAX_COUNT_ED25519_BATCH: usize = 256;

/// Max length for a debug message
const MAX_LENGTH_DEBUG: usize = 2 * MI;

/// Max length for an abort message
const MAX_LENGTH_ABORT: usize = 2 * MI;

/// Max length for a proof
const MAX_LENGTH_PROOF: usize = MI;
/// Max length for a set of instances
const MAX_LENGTH_INSTANCES: usize = MI;
/// Max number of items in one `proof_instance_batch_verify` call.
/// Arbitrary bound for memory / DoS (each item is a full ZK verify).
#[cfg(feature = "zk")]
const MAX_COUNT_PROOF_INSTANCE_BATCH: usize = 32;

#[inline(always)]
fn charge_host_call_gas<A: BackendApi + 'static, S: Storage + 'static, Q: Querier + 'static>(
    env: &Environment<A, S, Q>,
    store: &mut impl AsStoreMut,
) -> VmResult<()> {
    let gas = GasInfo::with_cost(env.gas_config.host_call_cost);
    process_gas_info(env, store, gas)
}

// Import implementations
//
// This block of do_* prefixed functions is tailored for Wasmer's
// Function::new_typed_with_env interface. Those require an env in the first
// argument and cannot capture other variables. Thus, everything is accessed
// through the env.

/// Reads a storage entry from the VM's storage into Wasm memory
pub fn do_db_read<A: BackendApi + 'static, S: Storage + 'static, Q: Querier + 'static>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    key_ptr: u32,
) -> VmResult<u32> {
    let (data, mut store) = env.data_and_store_mut();

    charge_host_call_gas(data, &mut store)?;

    let key = read_region(data, &mut store, key_ptr, MAX_LENGTH_DB_KEY)?;

    let (result, gas_info) = data.with_storage_from_context::<_, _>(|store| Ok(store.get(&key)))?;
    process_gas_info(data, &mut store, gas_info)?;
    let value = result?;

    let out_data = match value {
        Some(data) => data,
        None => return Ok(0),
    };
    write_to_contract(data, &mut store, &out_data)
}

/// Writes a storage entry from Wasm memory into the VM's storage
pub fn do_db_write<A: BackendApi + 'static, S: Storage + 'static, Q: Querier + 'static>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    key_ptr: u32,
    value_ptr: u32,
) -> VmResult<()> {
    let (data, mut store) = env.data_and_store_mut();

    charge_host_call_gas(data, &mut store)?;

    if data.is_storage_readonly() {
        return Err(VmError::write_access_denied());
    }

    /// Converts a region length error to a different variant for better understandability
    fn convert_error(e: VmError, kind: &'static str) -> VmError {
        if let VmError::CommunicationErr {
            source: CommunicationError::RegionLengthTooBig { length, max_length },
            ..
        } = e
        {
            VmError::generic_err(format!(
                "{kind} too big. Tried to write {length} bytes to storage, limit is {max_length}."
            ))
        } else {
            e
        }
    }

    let key = read_region(data, &mut store, key_ptr, MAX_LENGTH_DB_KEY)
        .map_err(|e| convert_error(e, "Key"))?;
    let value = read_region(data, &mut store, value_ptr, MAX_LENGTH_DB_VALUE)
        .map_err(|e| convert_error(e, "Value"))?;

    let (result, gas_info) =
        data.with_storage_from_context::<_, _>(|store| Ok(store.set(&key, &value)))?;
    process_gas_info(data, &mut store, gas_info)?;
    result?;

    Ok(())
}

pub fn do_db_remove<A: BackendApi + 'static, S: Storage + 'static, Q: Querier + 'static>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    key_ptr: u32,
) -> VmResult<()> {
    let (data, mut store) = env.data_and_store_mut();

    charge_host_call_gas(data, &mut store)?;

    if data.is_storage_readonly() {
        return Err(VmError::write_access_denied());
    }

    let key = read_region(data, &mut store, key_ptr, MAX_LENGTH_DB_KEY)?;

    let (result, gas_info) =
        data.with_storage_from_context::<_, _>(|store| Ok(store.remove(&key)))?;
    process_gas_info(data, &mut store, gas_info)?;
    result?;

    Ok(())
}

pub fn do_addr_validate<A: BackendApi + 'static, S: Storage + 'static, Q: Querier + 'static>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    source_ptr: u32,
) -> VmResult<u32> {
    let (data, mut store) = env.data_and_store_mut();

    charge_host_call_gas(data, &mut store)?;

    let source_data = read_region(data, &mut store, source_ptr, MAX_LENGTH_HUMAN_ADDRESS)?;
    if source_data.is_empty() {
        return write_to_contract(data, &mut store, b"Input is empty");
    }

    let string_gas_cost = GasInfo::with_cost(
        data.gas_config
            .string_from_bytes_cost
            .total_cost(source_data.len() as u64)?,
    );
    process_gas_info(data, &mut store, string_gas_cost)?;
    let source_string = match String::from_utf8(source_data) {
        Ok(s) => s,
        Err(_) => return write_to_contract(data, &mut store, b"Input is not valid UTF-8"),
    };

    let (result, gas_info) = data.api.addr_validate(&source_string);
    process_gas_info(data, &mut store, gas_info)?;
    match result {
        Ok(()) => Ok(0),
        Err(BackendError::UserErr { msg, .. }) => {
            write_to_contract(data, &mut store, msg.as_bytes())
        }
        Err(err) => Err(VmError::from(err)),
    }
}

pub fn do_addr_canonicalize<A: BackendApi + 'static, S: Storage + 'static, Q: Querier + 'static>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    source_ptr: u32,
    destination_ptr: u32,
) -> VmResult<u32> {
    let (data, mut store) = env.data_and_store_mut();

    charge_host_call_gas(data, &mut store)?;

    let source_data = read_region(data, &mut store, source_ptr, MAX_LENGTH_HUMAN_ADDRESS)?;
    if source_data.is_empty() {
        return write_to_contract(data, &mut store, b"Input is empty");
    }

    let string_gas_cost = GasInfo::with_cost(
        data.gas_config
            .string_from_bytes_cost
            .total_cost(source_data.len() as u64)?,
    );
    process_gas_info(data, &mut store, string_gas_cost)?;
    let source_string = match String::from_utf8(source_data) {
        Ok(s) => s,
        Err(_) => return write_to_contract(data, &mut store, b"Input is not valid UTF-8"),
    };

    let (result, gas_info) = data.api.addr_canonicalize(&source_string);
    process_gas_info(data, &mut store, gas_info)?;
    match result {
        Ok(canonical) => {
            write_region(data, &mut store, destination_ptr, canonical.as_slice())?;
            Ok(0)
        }
        Err(BackendError::UserErr { msg, .. }) => {
            Ok(write_to_contract(data, &mut store, msg.as_bytes())?)
        }
        Err(err) => Err(VmError::from(err)),
    }
}

pub fn do_addr_humanize<A: BackendApi + 'static, S: Storage + 'static, Q: Querier + 'static>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    source_ptr: u32,
    destination_ptr: u32,
) -> VmResult<u32> {
    let (data, mut store) = env.data_and_store_mut();

    charge_host_call_gas(data, &mut store)?;

    let canonical = read_region(data, &mut store, source_ptr, MAX_LENGTH_CANONICAL_ADDRESS)?;

    let (result, gas_info) = data.api.addr_humanize(&canonical);
    process_gas_info(data, &mut store, gas_info)?;
    match result {
        Ok(human) => {
            write_region(data, &mut store, destination_ptr, human.as_bytes())?;
            Ok(0)
        }
        Err(BackendError::UserErr { msg, .. }) => {
            Ok(write_to_contract(data, &mut store, msg.as_bytes())?)
        }
        Err(err) => Err(VmError::from(err)),
    }
}

/// Return code (error code) for a valid signature
const SECP256K1_VERIFY_CODE_VALID: u32 = 0;

/// Return code (error code) for an invalid signature
const SECP256K1_VERIFY_CODE_INVALID: u32 = 1;

/// Return code (error code) for a valid pairing
const BLS12_381_VALID_PAIRING: u32 = 0;

/// Return code (error code) for an invalid pairing
const BLS12_381_INVALID_PAIRING: u32 = 1;

/// Return code (error code) if the aggregating the points on curve was successful
const BLS12_381_AGGREGATE_SUCCESS: u32 = 0;

/// Return code (error code) for success when hashing to the curve
const BLS12_381_HASH_TO_CURVE_SUCCESS: u32 = 0;

/// Maximum size of continuous points passed to aggregate functions
const BLS12_381_MAX_AGGREGATE_SIZE: usize = 2 * MI;

/// Maximum size of the message passed to the hash-to-curve functions
const BLS12_381_MAX_MESSAGE_SIZE: usize = 5 * MI;

/// Maximum size of the destination passed to the hash-to-curve functions
const BLS12_381_MAX_DST_SIZE: usize = 5 * KI;

pub fn do_bls12_381_aggregate_g1<
    A: BackendApi + 'static,
    S: Storage + 'static,
    Q: Querier + 'static,
>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    g1s_ptr: u32,
    out_ptr: u32,
) -> VmResult<u32> {
    let (data, mut store) = env.data_and_store_mut();
    charge_host_call_gas(data, &mut store)?;

    let g1s = read_region(data, &mut store, g1s_ptr, BLS12_381_MAX_AGGREGATE_SIZE)?;

    let estimated_point_count = (g1s.len() / BLS12_381_G1_POINT_LEN) as u64;
    let gas_info = GasInfo::with_cost(
        data.gas_config
            .bls12_381_aggregate_g1_cost
            .total_cost(estimated_point_count)?,
    );
    process_gas_info(data, &mut store, gas_info)?;

    let code = match bls12_381_aggregate_g1(&g1s) {
        Ok(point) => {
            write_region(data, &mut store, out_ptr, &point)?;
            BLS12_381_AGGREGATE_SUCCESS
        }
        Err(err) => match err {
            CryptoError::InvalidPoint { .. } | CryptoError::Aggregation { .. } => err.code(),
            CryptoError::PairingEquality { .. }
            | CryptoError::BatchErr { .. }
            | CryptoError::GenericErr { .. }
            | CryptoError::InvalidHashFormat { .. }
            | CryptoError::InvalidPubkeyFormat { .. }
            | CryptoError::InvalidRecoveryParam { .. }
            | CryptoError::InvalidSignatureFormat { .. }
            | CryptoError::UnknownHashFunction { .. } => {
                panic!("Error must not happen for this call")
            }
        },
    };

    Ok(code)
}

pub fn do_bls12_381_aggregate_g2<
    A: BackendApi + 'static,
    S: Storage + 'static,
    Q: Querier + 'static,
>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    g2s_ptr: u32,
    out_ptr: u32,
) -> VmResult<u32> {
    let (data, mut store) = env.data_and_store_mut();

    charge_host_call_gas(data, &mut store)?;

    let g2s = read_region(data, &mut store, g2s_ptr, BLS12_381_MAX_AGGREGATE_SIZE)?;

    let estimated_point_count = (g2s.len() / BLS12_381_G2_POINT_LEN) as u64;
    let gas_info = GasInfo::with_cost(
        data.gas_config
            .bls12_381_aggregate_g2_cost
            .total_cost(estimated_point_count)?,
    );
    process_gas_info(data, &mut store, gas_info)?;

    let code = match bls12_381_aggregate_g2(&g2s) {
        Ok(point) => {
            write_region(data, &mut store, out_ptr, &point)?;
            BLS12_381_AGGREGATE_SUCCESS
        }
        Err(err) => match err {
            CryptoError::InvalidPoint { .. } | CryptoError::Aggregation { .. } => err.code(),
            CryptoError::PairingEquality { .. }
            | CryptoError::BatchErr { .. }
            | CryptoError::GenericErr { .. }
            | CryptoError::InvalidHashFormat { .. }
            | CryptoError::InvalidPubkeyFormat { .. }
            | CryptoError::InvalidRecoveryParam { .. }
            | CryptoError::InvalidSignatureFormat { .. }
            | CryptoError::UnknownHashFunction { .. } => {
                panic!("Error must not happen for this call")
            }
        },
    };

    Ok(code)
}

pub fn do_bls12_381_pairing_equality<
    A: BackendApi + 'static,
    S: Storage + 'static,
    Q: Querier + 'static,
>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    ps_ptr: u32,
    qs_ptr: u32,
    r_ptr: u32,
    s_ptr: u32,
) -> VmResult<u32> {
    let (data, mut store) = env.data_and_store_mut();

    charge_host_call_gas(data, &mut store)?;

    let ps = read_region(data, &mut store, ps_ptr, BLS12_381_MAX_AGGREGATE_SIZE)?;
    let qs = read_region(data, &mut store, qs_ptr, BLS12_381_MAX_AGGREGATE_SIZE)?;
    let r = read_region(data, &mut store, r_ptr, BLS12_381_G1_POINT_LEN)?;
    let s = read_region(data, &mut store, s_ptr, BLS12_381_G2_POINT_LEN)?;

    // The values here are only correct if ps and qs can be divided by the point size.
    // They are good enough for gas since we error in `bls12_381_pairing_equality` if the inputs are
    // not properly formatted.
    let estimated_n = (ps.len() / BLS12_381_G1_POINT_LEN) as u64;
    // The number of parings to compute (`n` on the left hand side and `k = n + 1` in total)
    let estimated_k = estimated_n + 1;

    let gas_info = GasInfo::with_cost(
        data.gas_config
            .bls12_381_pairing_equality_cost
            .total_cost(estimated_k)?,
    );
    process_gas_info(data, &mut store, gas_info)?;

    let code = match bls12_381_pairing_equality(&ps, &qs, &r, &s) {
        Ok(true) => BLS12_381_VALID_PAIRING,
        Ok(false) => BLS12_381_INVALID_PAIRING,
        Err(err) => match err {
            CryptoError::PairingEquality { .. } | CryptoError::InvalidPoint { .. } => err.code(),
            CryptoError::Aggregation { .. }
            | CryptoError::BatchErr { .. }
            | CryptoError::GenericErr { .. }
            | CryptoError::InvalidHashFormat { .. }
            | CryptoError::InvalidPubkeyFormat { .. }
            | CryptoError::InvalidRecoveryParam { .. }
            | CryptoError::InvalidSignatureFormat { .. }
            | CryptoError::UnknownHashFunction { .. } => {
                panic!("Error must not happen for this call")
            }
        },
    };

    Ok(code)
}

pub fn do_bls12_381_hash_to_g1<
    A: BackendApi + 'static,
    S: Storage + 'static,
    Q: Querier + 'static,
>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    hash_function: u32,
    msg_ptr: u32,
    dst_ptr: u32,
    out_ptr: u32,
) -> VmResult<u32> {
    let (data, mut store) = env.data_and_store_mut();

    charge_host_call_gas(data, &mut store)?;

    let msg = read_region(data, &mut store, msg_ptr, BLS12_381_MAX_MESSAGE_SIZE)?;
    let dst = read_region(data, &mut store, dst_ptr, BLS12_381_MAX_DST_SIZE)?;

    let gas_info = GasInfo::with_cost(data.gas_config.bls12_381_hash_to_g1_cost);
    process_gas_info(data, &mut store, gas_info)?;

    let hash_function = match HashFunction::from_u32(hash_function) {
        Ok(func) => func,
        Err(error) => return Ok(error.code()),
    };
    let point = bls12_381_hash_to_g1(hash_function, &msg, &dst);

    write_region(data, &mut store, out_ptr, &point)?;

    Ok(BLS12_381_HASH_TO_CURVE_SUCCESS)
}

pub fn do_bls12_381_hash_to_g2<
    A: BackendApi + 'static,
    S: Storage + 'static,
    Q: Querier + 'static,
>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    hash_function: u32,
    msg_ptr: u32,
    dst_ptr: u32,
    out_ptr: u32,
) -> VmResult<u32> {
    let (data, mut store) = env.data_and_store_mut();

    charge_host_call_gas(data, &mut store)?;

    let msg = read_region(data, &mut store, msg_ptr, BLS12_381_MAX_MESSAGE_SIZE)?;
    let dst = read_region(data, &mut store, dst_ptr, BLS12_381_MAX_DST_SIZE)?;

    let gas_info = GasInfo::with_cost(data.gas_config.bls12_381_hash_to_g2_cost);
    process_gas_info(data, &mut store, gas_info)?;

    let hash_function = match HashFunction::from_u32(hash_function) {
        Ok(func) => func,
        Err(error) => return Ok(error.code()),
    };
    let point = bls12_381_hash_to_g2(hash_function, &msg, &dst);

    write_region(data, &mut store, out_ptr, &point)?;

    Ok(BLS12_381_HASH_TO_CURVE_SUCCESS)
}

// ── BN254 host functions (feature "bn254") ────────────────────────────────
// EIP-196 / EIP-197 / EIP-1108 gas schedule from cosmwasm_crypto_bn254::gas.

#[cfg(feature = "bn254")]
/// Return code (error code) for a valid BN254 pairing
const BN254_VALID_PAIRING: u32 = 0;

#[cfg(feature = "bn254")]
/// Return code (error code) for an invalid BN254 pairing
const BN254_INVALID_PAIRING: u32 = 1;

#[cfg(feature = "bn254")]
/// Maximum size of BN254 input for add/scalar_mul (128 KB)
const BN254_MAX_INPUT_SIZE: usize = 128 * KI;

#[cfg(feature = "bn254")]
/// Maximum size of BN254 pairing input (2 MB)
const BN254_MAX_PAIRING_SIZE: usize = 2 * MI;

#[cfg(feature = "bn254")]
fn bn254_error_code(err: &Bn254Error) -> u32 {
    match err {
        Bn254Error::InvalidInputLength { .. } => 1,
        Bn254Error::InvalidPairingInputLength(_) => 2,
        Bn254Error::NotOnCurve => 3,
        Bn254Error::NotInSubgroup => 4,
        Bn254Error::InvalidFieldElement => 5,
        Bn254Error::BackendError(_) => 6,
        _ => 6,
    }
}

#[cfg(feature = "bn254")]
pub fn do_bn254_add<A: BackendApi + 'static, S: Storage + 'static, Q: Querier + 'static>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    input_ptr: u32,
    out_ptr: u32,
) -> VmResult<u32> {
    let (data, mut store) = env.data_and_store_mut();
    charge_host_call_gas(data, &mut store)?;

    let input = read_region(data, &mut store, input_ptr, BN254_MAX_INPUT_SIZE)?;

    let gas_info = GasInfo::with_cost(gas::BN254_ADD_COST);
    process_gas_info(data, &mut store, gas_info)?;

    let code = match bn254_add(&input) {
        Ok(point) => {
            write_region(data, &mut store, out_ptr, &point)?;
            0
        }
        Err(err) => bn254_error_code(&err),
    };
    Ok(code)
}

#[cfg(feature = "bn254")]
pub fn do_bn254_scalar_mul<A: BackendApi + 'static, S: Storage + 'static, Q: Querier + 'static>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    input_ptr: u32,
    out_ptr: u32,
) -> VmResult<u32> {
    let (data, mut store) = env.data_and_store_mut();
    charge_host_call_gas(data, &mut store)?;

    let input = read_region(data, &mut store, input_ptr, BN254_MAX_INPUT_SIZE)?;

    let gas_info = GasInfo::with_cost(gas::BN254_SCALAR_MUL_COST);
    process_gas_info(data, &mut store, gas_info)?;

    let code = match bn254_scalar_mul(&input) {
        Ok(point) => {
            write_region(data, &mut store, out_ptr, &point)?;
            0
        }
        Err(err) => bn254_error_code(&err),
    };
    Ok(code)
}

#[cfg(feature = "bn254")]
pub fn do_bn254_pairing_equality<
    A: BackendApi + 'static,
    S: Storage + 'static,
    Q: Querier + 'static,
>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    input_ptr: u32,
) -> VmResult<u32> {
    let (data, mut store) = env.data_and_store_mut();
    charge_host_call_gas(data, &mut store)?;

    let input = read_region(data, &mut store, input_ptr, BN254_MAX_PAIRING_SIZE)?;

    // Estimate number of pairs for gas
    let estimated_n = if input.len() >= (G1_BYTES + G2_BYTES) {
        input.len() / (G1_BYTES + G2_BYTES)
    } else {
        0
    };
    let gas_info = GasInfo::with_cost(gas::pairing_cost(estimated_n));
    process_gas_info(data, &mut store, gas_info)?;

    let code = match bn254_pairing_equality(&input) {
        Ok(true) => BN254_VALID_PAIRING,
        Ok(false) => BN254_INVALID_PAIRING,
        Err(err) => bn254_error_code(&err),
    };
    Ok(code)
}

// ── Hash host functions (feature "hash-blake") ────────────────────────────
// Native deterministic BLAKE2b-256 / BLAKE3-256 digests (CPU only, never GPU
// on consensus path). Gas: constant base + per-byte.

#[cfg(feature = "hash-blake")]
use cosmwasm_crypto::{blake2b_256, blake3_256};

#[cfg(feature = "hash-blake")]
/// Base gas cost for a blake hash operation
const BLAKE_BASE_COST: u64 = 100;
#[cfg(feature = "hash-blake")]
/// Per-byte gas cost for a blake hash operation
const BLAKE_PER_BYTE_COST: u64 = 1;
#[cfg(feature = "hash-blake")]
/// Maximum input size for blake hash operations (1 MB)
const BLAKE_MAX_INPUT_SIZE: usize = 1 * MI;

#[cfg(feature = "hash-blake")]
pub fn do_blake2b_256<A: BackendApi + 'static, S: Storage + 'static, Q: Querier + 'static>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    input_ptr: u32,
    out_ptr: u32,
) -> VmResult<u32> {
    let (data, mut store) = env.data_and_store_mut();
    charge_host_call_gas(data, &mut store)?;

    let input = read_region(data, &mut store, input_ptr, BLAKE_MAX_INPUT_SIZE)?;

    let gas_cost = BLAKE_BASE_COST + (input.len() as u64) * BLAKE_PER_BYTE_COST;
    let gas_info = GasInfo::with_cost(gas_cost);
    process_gas_info(data, &mut store, gas_info)?;

    let result = blake2b_256(&input);
    write_region(data, &mut store, out_ptr, &result)?;
    Ok(0)
}

#[cfg(feature = "hash-blake")]
pub fn do_blake3_256<A: BackendApi + 'static, S: Storage + 'static, Q: Querier + 'static>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    input_ptr: u32,
    out_ptr: u32,
) -> VmResult<u32> {
    let (data, mut store) = env.data_and_store_mut();
    charge_host_call_gas(data, &mut store)?;

    let input = read_region(data, &mut store, input_ptr, BLAKE_MAX_INPUT_SIZE)?;

    let gas_cost = BLAKE_BASE_COST + (input.len() as u64) * BLAKE_PER_BYTE_COST;
    let gas_info = GasInfo::with_cost(gas_cost);
    process_gas_info(data, &mut store, gas_info)?;

    let result = blake3_256(&input);
    write_region(data, &mut store, out_ptr, &result)?;
    Ok(0)
}

// ── Poseidon host functions (feature "hash-poseidon") ─────────────────────
// Algebraic Poseidon over Pasta (Zcash) and BLS12-377 (Penumbra). CPU only.
// Gas: scheduled base + per field element (never wall-time / GPU).

#[cfg(feature = "hash-poseidon")]
use cosmwasm_crypto::{
    poseidon377_hash_bytes, poseidon_hash_pallas_bytes, poseidon_hash_vesta_bytes,
    PASTA_FIELD_BYTES, POSEIDON377_FIELD_BYTES,
};

#[cfg(feature = "hash-poseidon")]
/// Base gas for one Poseidon permutation/hash invocation.
const POSEIDON_BASE_COST: u64 = 50_000;
#[cfg(feature = "hash-poseidon")]
/// Per field element absorbed (in addition to base).
const POSEIDON_PER_ELEMENT_COST: u64 = 25_000;
#[cfg(feature = "hash-poseidon")]
/// Max concatenated field-element payload (16 × 32 for Pasta).
const POSEIDON_MAX_INPUT_BYTES: usize = 16 * PASTA_FIELD_BYTES;

#[cfg(feature = "hash-poseidon")]
fn poseidon_gas_for_elements(n_elements: usize) -> u64 {
    POSEIDON_BASE_COST + (n_elements as u64) * POSEIDON_PER_ELEMENT_COST
}

/// Host: Poseidon-Hash over Pallas base field (`P128Pow5T3`, ConstantLength).
///
/// `inputs_ptr` → region of `n*32` LE field elements (`n` in 1..=16).
/// `out_ptr` → 32-byte LE field element.
/// Returns 0 on success, 1 on invalid encoding/length.
#[cfg(feature = "hash-poseidon")]
pub fn do_poseidon_hash_pallas<
    A: BackendApi + 'static,
    S: Storage + 'static,
    Q: Querier + 'static,
>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    inputs_ptr: u32,
    out_ptr: u32,
) -> VmResult<u32> {
    let (data, mut store) = env.data_and_store_mut();
    charge_host_call_gas(data, &mut store)?;

    let input = read_region(data, &mut store, inputs_ptr, POSEIDON_MAX_INPUT_BYTES)?;
    let n = if input.len() % PASTA_FIELD_BYTES == 0 {
        input.len() / PASTA_FIELD_BYTES
    } else {
        0
    };
    let gas_info = GasInfo::with_cost(poseidon_gas_for_elements(n.max(1)));
    process_gas_info(data, &mut store, gas_info)?;

    match poseidon_hash_pallas_bytes(&input) {
        Ok(result) => {
            write_region(data, &mut store, out_ptr, &result)?;
            Ok(0)
        }
        Err(_) => Ok(1),
    }
}

/// Host: Poseidon-Hash over Vesta base field (`P128Pow5T3`, ConstantLength).
#[cfg(feature = "hash-poseidon")]
pub fn do_poseidon_hash_vesta<
    A: BackendApi + 'static,
    S: Storage + 'static,
    Q: Querier + 'static,
>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    inputs_ptr: u32,
    out_ptr: u32,
) -> VmResult<u32> {
    let (data, mut store) = env.data_and_store_mut();
    charge_host_call_gas(data, &mut store)?;

    let input = read_region(data, &mut store, inputs_ptr, POSEIDON_MAX_INPUT_BYTES)?;
    let n = if input.len() % PASTA_FIELD_BYTES == 0 {
        input.len() / PASTA_FIELD_BYTES
    } else {
        0
    };
    let gas_info = GasInfo::with_cost(poseidon_gas_for_elements(n.max(1)));
    process_gas_info(data, &mut store, gas_info)?;

    match poseidon_hash_vesta_bytes(&input) {
        Ok(result) => {
            write_region(data, &mut store, out_ptr, &result)?;
            Ok(0)
        }
        Err(_) => Ok(1),
    }
}

/// Host: Penumbra Poseidon377 (`hash_1`…`hash_7` over BLS12-377 scalar).
///
/// `domain_ptr` → 32-byte domain separator Fq.
/// `inputs_ptr` → `n*32` message field elements (`n` in 1..=7).
/// `out_ptr` → 32-byte LE Fq.
/// Returns 0 on success, 1 on invalid encoding/length.
#[cfg(feature = "hash-poseidon")]
pub fn do_poseidon377_hash<A: BackendApi + 'static, S: Storage + 'static, Q: Querier + 'static>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    domain_ptr: u32,
    inputs_ptr: u32,
    out_ptr: u32,
) -> VmResult<u32> {
    let (data, mut store) = env.data_and_store_mut();
    charge_host_call_gas(data, &mut store)?;

    let domain = read_region(data, &mut store, domain_ptr, POSEIDON377_FIELD_BYTES)?;
    // 7 * 32 max message payload
    let input = read_region(data, &mut store, inputs_ptr, 7 * POSEIDON377_FIELD_BYTES)?;
    let n = if input.len() % POSEIDON377_FIELD_BYTES == 0 {
        input.len() / POSEIDON377_FIELD_BYTES
    } else {
        0
    };
    // domain + message elements
    let gas_info = GasInfo::with_cost(poseidon_gas_for_elements(n.saturating_add(1).max(1)));
    process_gas_info(data, &mut store, gas_info)?;

    match poseidon377_hash_bytes(&domain, &input) {
        Ok(result) => {
            write_region(data, &mut store, out_ptr, &result)?;
            Ok(0)
        }
        Err(_) => Ok(1),
    }
}

pub fn do_secp256k1_verify<A: BackendApi + 'static, S: Storage + 'static, Q: Querier + 'static>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    hash_ptr: u32,
    signature_ptr: u32,
    pubkey_ptr: u32,
) -> VmResult<u32> {
    let (data, mut store) = env.data_and_store_mut();

    charge_host_call_gas(data, &mut store)?;

    let hash = read_region(data, &mut store, hash_ptr, MESSAGE_HASH_MAX_LEN)?;
    let signature = read_region(data, &mut store, signature_ptr, ECDSA_SIGNATURE_LEN)?;
    let pubkey = read_region(data, &mut store, pubkey_ptr, ECDSA_PUBKEY_MAX_LEN)?;

    let gas_info = GasInfo::with_cost(data.gas_config.secp256k1_verify_cost);
    process_gas_info(data, &mut store, gas_info)?;

    let result = secp256k1_verify(&hash, &signature, &pubkey);
    let code = match result {
        Ok(valid) => {
            if valid {
                SECP256K1_VERIFY_CODE_VALID
            } else {
                SECP256K1_VERIFY_CODE_INVALID
            }
        }
        Err(err) => match err {
            CryptoError::InvalidHashFormat { .. }
            | CryptoError::InvalidPubkeyFormat { .. }
            | CryptoError::InvalidSignatureFormat { .. }
            | CryptoError::GenericErr { .. } => err.code(),
            CryptoError::Aggregation { .. }
            | CryptoError::PairingEquality { .. }
            | CryptoError::BatchErr { .. }
            | CryptoError::InvalidPoint { .. }
            | CryptoError::InvalidRecoveryParam { .. }
            | CryptoError::UnknownHashFunction { .. } => {
                panic!("Error must not happen for this call")
            }
        },
    };
    Ok(code)
}

pub fn do_secp256k1_recover_pubkey<
    A: BackendApi + 'static,
    S: Storage + 'static,
    Q: Querier + 'static,
>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    hash_ptr: u32,
    signature_ptr: u32,
    recover_param: u32,
) -> VmResult<u64> {
    let (data, mut store) = env.data_and_store_mut();

    charge_host_call_gas(data, &mut store)?;

    let hash = read_region(data, &mut store, hash_ptr, MESSAGE_HASH_MAX_LEN)?;
    let signature = read_region(data, &mut store, signature_ptr, ECDSA_SIGNATURE_LEN)?;

    let recover_param: u8 = match recover_param.try_into() {
        Ok(rp) => rp,
        Err(_) => return Ok((CryptoError::invalid_recovery_param().code() as u64) << 32),
    };

    let gas_info = GasInfo::with_cost(data.gas_config.secp256k1_recover_pubkey_cost);
    process_gas_info(data, &mut store, gas_info)?;

    let result = secp256k1_recover_pubkey(&hash, &signature, recover_param);
    match result {
        Ok(pubkey) => {
            let pubkey_ptr = write_to_contract(data, &mut store, pubkey.as_ref())?;
            Ok(to_low_half(pubkey_ptr))
        }
        Err(err) => match err {
            CryptoError::InvalidHashFormat { .. }
            | CryptoError::InvalidSignatureFormat { .. }
            | CryptoError::InvalidRecoveryParam { .. }
            | CryptoError::GenericErr { .. } => Ok(to_high_half(err.code())),
            CryptoError::Aggregation { .. }
            | CryptoError::PairingEquality { .. }
            | CryptoError::BatchErr { .. }
            | CryptoError::InvalidPoint { .. }
            | CryptoError::InvalidPubkeyFormat { .. }
            | CryptoError::UnknownHashFunction { .. } => {
                panic!("Error must not happen for this call")
            }
        },
    }
}

/// Return code (error code) for a valid signature
const SECP256R1_VERIFY_CODE_VALID: u32 = 0;

/// Return code (error code) for an invalid signature
const SECP256R1_VERIFY_CODE_INVALID: u32 = 1;

pub fn do_secp256r1_verify<A: BackendApi + 'static, S: Storage + 'static, Q: Querier + 'static>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    hash_ptr: u32,
    signature_ptr: u32,
    pubkey_ptr: u32,
) -> VmResult<u32> {
    let (data, mut store) = env.data_and_store_mut();

    charge_host_call_gas(data, &mut store)?;

    let hash = read_region(data, &mut store, hash_ptr, MESSAGE_HASH_MAX_LEN)?;
    let signature = read_region(data, &mut store, signature_ptr, ECDSA_SIGNATURE_LEN)?;
    let pubkey = read_region(data, &mut store, pubkey_ptr, ECDSA_PUBKEY_MAX_LEN)?;

    let gas_info = GasInfo::with_cost(data.gas_config.secp256r1_verify_cost);
    process_gas_info(data, &mut store, gas_info)?;

    let result = secp256r1_verify(&hash, &signature, &pubkey);
    let code = match result {
        Ok(valid) => {
            if valid {
                SECP256R1_VERIFY_CODE_VALID
            } else {
                SECP256R1_VERIFY_CODE_INVALID
            }
        }
        Err(err) => match err {
            CryptoError::InvalidHashFormat { .. }
            | CryptoError::InvalidPubkeyFormat { .. }
            | CryptoError::InvalidSignatureFormat { .. }
            | CryptoError::GenericErr { .. } => err.code(),
            CryptoError::Aggregation { .. }
            | CryptoError::PairingEquality { .. }
            | CryptoError::BatchErr { .. }
            | CryptoError::InvalidPoint { .. }
            | CryptoError::InvalidRecoveryParam { .. }
            | CryptoError::UnknownHashFunction { .. } => {
                panic!("Error must not happen for this call")
            }
        },
    };
    Ok(code)
}

pub fn do_secp256r1_recover_pubkey<
    A: BackendApi + 'static,
    S: Storage + 'static,
    Q: Querier + 'static,
>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    hash_ptr: u32,
    signature_ptr: u32,
    recover_param: u32,
) -> VmResult<u64> {
    let (data, mut store) = env.data_and_store_mut();

    charge_host_call_gas(data, &mut store)?;

    let hash = read_region(data, &mut store, hash_ptr, MESSAGE_HASH_MAX_LEN)?;
    let signature = read_region(data, &mut store, signature_ptr, ECDSA_SIGNATURE_LEN)?;
    let recover_param: u8 = match recover_param.try_into() {
        Ok(rp) => rp,
        Err(_) => return Ok((CryptoError::invalid_recovery_param().code() as u64) << 32),
    };

    let gas_info = GasInfo::with_cost(data.gas_config.secp256r1_recover_pubkey_cost);
    process_gas_info(data, &mut store, gas_info)?;

    let result = secp256r1_recover_pubkey(&hash, &signature, recover_param);
    match result {
        Ok(pubkey) => {
            let pubkey_ptr = write_to_contract(data, &mut store, pubkey.as_ref())?;
            Ok(to_low_half(pubkey_ptr))
        }
        Err(err) => match err {
            CryptoError::InvalidHashFormat { .. }
            | CryptoError::InvalidSignatureFormat { .. }
            | CryptoError::InvalidRecoveryParam { .. }
            | CryptoError::GenericErr { .. } => Ok(to_high_half(err.code())),
            CryptoError::Aggregation { .. }
            | CryptoError::PairingEquality { .. }
            | CryptoError::BatchErr { .. }
            | CryptoError::InvalidPoint { .. }
            | CryptoError::InvalidPubkeyFormat { .. }
            | CryptoError::UnknownHashFunction { .. } => {
                panic!("Error must not happen for this call")
            }
        },
    }
}

// ── RedPallas / RedJubjub (feature "redpallas") ───────────────────────────
// Orchard RedPallas + Sapling RedJubjub via reddsa. CPU only, scheduled gas.

#[cfg(feature = "redpallas")]
use cosmwasm_crypto::{
    redjubjub_binding_verify, redjubjub_spendauth_verify, redpallas_binding_verify,
    redpallas_spendauth_verify, REDPALLAS_MESSAGE_MAX_LEN, REDPALLAS_SIGNATURE_LEN,
    REDPALLAS_VK_LEN,
};

#[cfg(feature = "redpallas")]
const REDPALLAS_VERIFY_CODE_VALID: u32 = 0;
#[cfg(feature = "redpallas")]
const REDPALLAS_VERIFY_CODE_INVALID: u32 = 1;

/// Host: RedPallas SpendAuth verify (Orchard / vote-sdk).
/// `(message, signature, pubkey) → 0 valid, 1 invalid, >1 format error`
#[cfg(feature = "redpallas")]
pub fn do_redpallas_spendauth_verify<
    A: BackendApi + 'static,
    S: Storage + 'static,
    Q: Querier + 'static,
>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    message_ptr: u32,
    signature_ptr: u32,
    pubkey_ptr: u32,
) -> VmResult<u32> {
    let (data, mut store) = env.data_and_store_mut();
    charge_host_call_gas(data, &mut store)?;

    let message = read_region(data, &mut store, message_ptr, REDPALLAS_MESSAGE_MAX_LEN)?;
    let signature = read_region(data, &mut store, signature_ptr, REDPALLAS_SIGNATURE_LEN)?;
    let pubkey = read_region(data, &mut store, pubkey_ptr, REDPALLAS_VK_LEN)?;

    let gas_info = GasInfo::with_cost(data.gas_config.redpallas_verify_cost);
    process_gas_info(data, &mut store, gas_info)?;

    let result = redpallas_spendauth_verify(&message, &signature, &pubkey);
    Ok(match result {
        Ok(true) => REDPALLAS_VERIFY_CODE_VALID,
        Ok(false) => REDPALLAS_VERIFY_CODE_INVALID,
        Err(err) => match err {
            CryptoError::InvalidPubkeyFormat { .. }
            | CryptoError::InvalidSignatureFormat { .. }
            | CryptoError::GenericErr { .. } => err.code(),
            _ => panic!("Error must not happen for redpallas_spendauth_verify"),
        },
    })
}

/// Host: RedPallas Binding verify (Orchard).
#[cfg(feature = "redpallas")]
pub fn do_redpallas_binding_verify<
    A: BackendApi + 'static,
    S: Storage + 'static,
    Q: Querier + 'static,
>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    message_ptr: u32,
    signature_ptr: u32,
    pubkey_ptr: u32,
) -> VmResult<u32> {
    let (data, mut store) = env.data_and_store_mut();
    charge_host_call_gas(data, &mut store)?;

    let message = read_region(data, &mut store, message_ptr, REDPALLAS_MESSAGE_MAX_LEN)?;
    let signature = read_region(data, &mut store, signature_ptr, REDPALLAS_SIGNATURE_LEN)?;
    let pubkey = read_region(data, &mut store, pubkey_ptr, REDPALLAS_VK_LEN)?;

    let gas_info = GasInfo::with_cost(data.gas_config.redpallas_verify_cost);
    process_gas_info(data, &mut store, gas_info)?;

    let result = redpallas_binding_verify(&message, &signature, &pubkey);
    Ok(match result {
        Ok(true) => REDPALLAS_VERIFY_CODE_VALID,
        Ok(false) => REDPALLAS_VERIFY_CODE_INVALID,
        Err(err) => match err {
            CryptoError::InvalidPubkeyFormat { .. }
            | CryptoError::InvalidSignatureFormat { .. }
            | CryptoError::GenericErr { .. } => err.code(),
            _ => panic!("Error must not happen for redpallas_binding_verify"),
        },
    })
}

/// Host: RedJubjub SpendAuth verify (Sapling).
#[cfg(feature = "redpallas")]
pub fn do_redjubjub_spendauth_verify<
    A: BackendApi + 'static,
    S: Storage + 'static,
    Q: Querier + 'static,
>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    message_ptr: u32,
    signature_ptr: u32,
    pubkey_ptr: u32,
) -> VmResult<u32> {
    let (data, mut store) = env.data_and_store_mut();
    charge_host_call_gas(data, &mut store)?;

    let message = read_region(data, &mut store, message_ptr, REDPALLAS_MESSAGE_MAX_LEN)?;
    let signature = read_region(data, &mut store, signature_ptr, REDPALLAS_SIGNATURE_LEN)?;
    let pubkey = read_region(data, &mut store, pubkey_ptr, REDPALLAS_VK_LEN)?;

    let gas_info = GasInfo::with_cost(data.gas_config.redjubjub_verify_cost);
    process_gas_info(data, &mut store, gas_info)?;

    let result = redjubjub_spendauth_verify(&message, &signature, &pubkey);
    Ok(match result {
        Ok(true) => REDPALLAS_VERIFY_CODE_VALID,
        Ok(false) => REDPALLAS_VERIFY_CODE_INVALID,
        Err(err) => match err {
            CryptoError::InvalidPubkeyFormat { .. }
            | CryptoError::InvalidSignatureFormat { .. }
            | CryptoError::GenericErr { .. } => err.code(),
            _ => panic!("Error must not happen for redjubjub_spendauth_verify"),
        },
    })
}

/// Host: RedJubjub Binding verify (Sapling).
#[cfg(feature = "redpallas")]
pub fn do_redjubjub_binding_verify<
    A: BackendApi + 'static,
    S: Storage + 'static,
    Q: Querier + 'static,
>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    message_ptr: u32,
    signature_ptr: u32,
    pubkey_ptr: u32,
) -> VmResult<u32> {
    let (data, mut store) = env.data_and_store_mut();
    charge_host_call_gas(data, &mut store)?;

    let message = read_region(data, &mut store, message_ptr, REDPALLAS_MESSAGE_MAX_LEN)?;
    let signature = read_region(data, &mut store, signature_ptr, REDPALLAS_SIGNATURE_LEN)?;
    let pubkey = read_region(data, &mut store, pubkey_ptr, REDPALLAS_VK_LEN)?;

    let gas_info = GasInfo::with_cost(data.gas_config.redjubjub_verify_cost);
    process_gas_info(data, &mut store, gas_info)?;

    let result = redjubjub_binding_verify(&message, &signature, &pubkey);
    Ok(match result {
        Ok(true) => REDPALLAS_VERIFY_CODE_VALID,
        Ok(false) => REDPALLAS_VERIFY_CODE_INVALID,
        Err(err) => match err {
            CryptoError::InvalidPubkeyFormat { .. }
            | CryptoError::InvalidSignatureFormat { .. }
            | CryptoError::GenericErr { .. } => err.code(),
            _ => panic!("Error must not happen for redjubjub_binding_verify"),
        },
    })
}

/// Return code (error code) for a valid signature
const ED25519_VERIFY_CODE_VALID: u32 = 0;

/// Return code (error code) for an invalid signature
const ED25519_VERIFY_CODE_INVALID: u32 = 1;

pub fn do_ed25519_verify<A: BackendApi + 'static, S: Storage + 'static, Q: Querier + 'static>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    message_ptr: u32,
    signature_ptr: u32,
    pubkey_ptr: u32,
) -> VmResult<u32> {
    let (data, mut store) = env.data_and_store_mut();

    charge_host_call_gas(data, &mut store)?;

    let message = read_region(data, &mut store, message_ptr, MAX_LENGTH_ED25519_MESSAGE)?;
    let signature = read_region(
        data,
        &mut store,
        signature_ptr,
        MAX_LENGTH_ED25519_SIGNATURE,
    )?;
    let pubkey = read_region(data, &mut store, pubkey_ptr, EDDSA_PUBKEY_LEN)?;

    let gas_info = GasInfo::with_cost(data.gas_config.ed25519_verify_cost);
    process_gas_info(data, &mut store, gas_info)?;

    let result = ed25519_verify(&message, &signature, &pubkey);
    let code = match result {
        Ok(valid) => {
            if valid {
                ED25519_VERIFY_CODE_VALID
            } else {
                ED25519_VERIFY_CODE_INVALID
            }
        }
        Err(err) => match err {
            CryptoError::InvalidPubkeyFormat { .. }
            | CryptoError::InvalidSignatureFormat { .. }
            | CryptoError::GenericErr { .. } => err.code(),
            CryptoError::Aggregation { .. }
            | CryptoError::PairingEquality { .. }
            | CryptoError::BatchErr { .. }
            | CryptoError::InvalidPoint { .. }
            | CryptoError::InvalidHashFormat { .. }
            | CryptoError::InvalidRecoveryParam { .. }
            | CryptoError::UnknownHashFunction { .. } => {
                panic!("Error must not happen for this call")
            }
        },
    };
    Ok(code)
}

pub fn do_ed25519_batch_verify<
    A: BackendApi + 'static,
    S: Storage + 'static,
    Q: Querier + 'static,
>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    messages_ptr: u32,
    signatures_ptr: u32,
    public_keys_ptr: u32,
) -> VmResult<u32> {
    let (data, mut store) = env.data_and_store_mut();

    charge_host_call_gas(data, &mut store)?;

    let messages = read_region(
        data,
        &mut store,
        messages_ptr,
        (MAX_LENGTH_ED25519_MESSAGE + 4) * MAX_COUNT_ED25519_BATCH,
    )?;
    let signatures = read_region(
        data,
        &mut store,
        signatures_ptr,
        (MAX_LENGTH_ED25519_SIGNATURE + 4) * MAX_COUNT_ED25519_BATCH,
    )?;
    let public_keys = read_region(
        data,
        &mut store,
        public_keys_ptr,
        (EDDSA_PUBKEY_LEN + 4) * MAX_COUNT_ED25519_BATCH,
    )?;

    let messages = decode_sections(&messages)?;
    let signatures = decode_sections(&signatures)?;
    let public_keys = decode_sections(&public_keys)?;

    let gas_cost = if public_keys.len() == 1 {
        &data.gas_config.ed25519_batch_verify_one_pubkey_cost
    } else {
        &data.gas_config.ed25519_batch_verify_cost
    };
    let gas_info = GasInfo::with_cost(gas_cost.total_cost(signatures.len() as u64)?);
    process_gas_info(data, &mut store, gas_info)?;

    let result = ed25519_batch_verify(&mut OsRng, &messages, &signatures, &public_keys);
    let code = match result {
        Ok(valid) => {
            if valid {
                ED25519_VERIFY_CODE_VALID
            } else {
                ED25519_VERIFY_CODE_INVALID
            }
        }
        Err(err) => match err {
            CryptoError::BatchErr { .. }
            | CryptoError::InvalidPubkeyFormat { .. }
            | CryptoError::InvalidSignatureFormat { .. }
            | CryptoError::GenericErr { .. } => err.code(),
            CryptoError::Aggregation { .. }
            | CryptoError::PairingEquality { .. }
            | CryptoError::InvalidHashFormat { .. }
            | CryptoError::InvalidPoint { .. }
            | CryptoError::InvalidRecoveryParam { .. }
            | CryptoError::UnknownHashFunction { .. } => {
                panic!("Error must not happen for this call")
            }
        },
    };
    Ok(code)
}

/// Scheduled gas units for one Path A verify item (see docs/ZK-VERIFY-GAS.md).
/// `units = 1 + max(1, ceil(proof/1024)) + ceil(instances/32)`.
#[cfg(feature = "zk")]
fn proof_instance_verify_gas_units(proof_len: usize, instances_len: usize) -> u64 {
    let proof_kib = (proof_len as u64).div_ceil(1024).max(1);
    let pi_limbs = (instances_len as u64).div_ceil(32);
    1u64.saturating_add(proof_kib).saturating_add(pi_limbs)
}

/// Path A: resolve `zkid` → `AnyVerifyingKey` via CircuitInfo + host cache / cold Circuit.
/// Never reads the contract's sandboxed KVStore for circuit data. Pin/LRU unchanged.
#[cfg(feature = "zk")]
fn load_verifying_key_for_zkid<
    A: BackendApi + 'static,
    S: Storage + 'static,
    Q: Querier + 'static,
>(
    data: &Environment<A, S, Q>,
    store: &mut impl wasmer::AsStoreMut,
    zkid: u64,
) -> VmResult<zk_cosmwasm::AnyVerifyingKey> {
    use cosmwasm_std::{from_json, ContractResult, Empty, QueryRequest, SystemResult, WasmQuery};
    use cosmwasm_std::{CircuitInfoResponse, CircuitResponse};

    // ── Step 1: resolve zkid → circuit_key via CircuitInfo (metadata only) ──
    let info_req = QueryRequest::<Empty>::Wasm(WasmQuery::CircuitInfo { zk_id: zkid });
    let info_raw = match query_raw(data, store, &info_req)? {
        SystemResult::Ok(ContractResult::Ok(bin)) => bin,
        SystemResult::Ok(ContractResult::Err(e)) => {
            return Err(VmError::generic_err(format!(
                "CircuitInfo query error: {e}"
            )));
        }
        SystemResult::Err(e) => {
            return Err(VmError::generic_err(format!(
                "CircuitInfo system error: {e}"
            )));
        }
    };
    let info: CircuitInfoResponse = from_json(info_raw.as_slice())
        .map_err(|e| VmError::generic_err(format!("parse CircuitInfoResponse: {e}")))?;

    let circuit_key: [u8; 72] = info.circuit_key.as_slice().try_into().map_err(|_| {
        VmError::generic_err(format!(
            "circuit_key must be 72 bytes, got {}",
            info.circuit_key.len()
        ))
    })?;

    // ── Step 2: Path A — host cache load (no full circuit over querier) ──
    // Outer Option: loader installed? Inner Option: cache hit?
    let cached_vk = data
        .with_circuit_loader(|loader| loader(circuit_key))?
        .flatten();

    if let Some(vk) = cached_vk {
        return Ok(vk);
    }

    // ── Step 3: cold path — full circuit bytes only if cache miss ──
    let circuit_req = QueryRequest::<Empty>::Wasm(WasmQuery::Circuit { zk_id: zkid });
    let circuit_raw = match query_raw(data, store, &circuit_req)? {
        SystemResult::Ok(ContractResult::Ok(bin)) => bin,
        SystemResult::Ok(ContractResult::Err(e)) => {
            return Err(VmError::generic_err(format!("Circuit query error: {e}")));
        }
        SystemResult::Err(e) => {
            return Err(VmError::generic_err(format!("Circuit system error: {e}")));
        }
    };
    let circuit_resp: CircuitResponse = from_json(circuit_raw.as_slice())
        .map_err(|e| VmError::generic_err(format!("parse CircuitResponse: {e}")))?;
    let serialized = crate::zk::deserialize_circuit_data(circuit_resp.data.as_slice())?;
    let mut full = serialized.body;
    full.extend_from_slice(&serialized.footer);
    // Integrity on cold blob (includes H-05 layout when cs/vk lens set).
    let _footer = crate::zk::check_circuit(&full).map_err(VmError::zk_err)?;
    let loaded =
        zk_cosmwasm::AnyVerifyingKey::try_from(full.as_slice()).map_err(|e| VmError::zk_err(e))?;
    // H-06: cold-path re-bind — loaded VK identity must match CircuitInfo key.
    if loaded.circuit_key() != circuit_key {
        return Err(VmError::generic_err(format!(
            "cold-path circuit_key mismatch: CircuitInfo {} vs footer {}",
            hex::encode(circuit_key),
            hex::encode(loaded.circuit_key())
        )));
    }
    Ok(loaded)
}

/// Build + arity-check public instances for a VK (footer.curve_id routing, H-05).
#[cfg(feature = "zk")]
fn prepare_instances_for_vk(
    vk: &zk_cosmwasm::AnyVerifyingKey,
    instances_bytes: &[u8],
) -> VmResult<zk_cosmwasm::AnyInstance> {
    // Instance routing uses **footer.curve_id**, never app zkid (D7).
    let curve_id = vk.curve_id() as u32;
    let i = zk_cosmwasm::AnyInstance::try_from_bytes(curve_id, instances_bytes)
        .map_err(VmError::zk_err)?;

    // H-05: bind footer.i to provided public-input arity when footer claims n>0.
    let expected_i = vk.public_input_count() as usize;
    let got_i = instance_public_input_count(&i);
    if expected_i > 0 && got_i != expected_i {
        return Err(VmError::zk_err(zk_cosmwasm::ZkError::format_err(format!(
            "public input count {got_i} != footer.i {expected_i}"
        ))));
    }
    Ok(i)
}

/// Path A proof verification:
/// 1. Lightweight `WasmQuery::CircuitInfo` → 72-byte `circuit_key` (no full blob on the wire).
/// 2. Host circuit cache `load_circuit(key)` → already-deserialized `AnyVerifyingKey`.
/// 3. On cache miss only: full `WasmQuery::Circuit` blob as cold path.
///
/// Never reads the contract's sandboxed KVStore for circuit data.
///
/// Optional feature `gpu` (default OFF): eligible verify may use a CPU-golden
/// `VerifierBackend` with runtime GPU detect + CPU fallback. Gas remains the
/// scheduled `halo2_proof_instance_verify_cost` below — never wall-time.
/// Blake hosts never use GPU. Pin/LRU unchanged (load ≠ pin).
/// See docs/research/gpu-accel/DESIGN-G1-verifier-backend.md
#[cfg(feature = "zk")]
pub fn do_proof_instance_verify<
    A: BackendApi + 'static,
    S: Storage + 'static,
    Q: Querier + 'static,
>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    zkid: u32,
    proof_ptr: u32,
    proof_len: u32,
    instances_ptr: u32,
    instances_len: u32,
) -> VmResult<u32> {
    let (data, mut store) = env.data_and_store_mut();
    charge_host_call_gas(data, &mut store)?;

    let proof_bytes = read_region(
        data,
        &mut store,
        proof_ptr,
        std::cmp::min(proof_len as usize, MAX_LENGTH_PROOF),
    )?;
    let instances_bytes = read_region(
        data,
        &mut store,
        instances_ptr,
        std::cmp::min(instances_len as usize, MAX_LENGTH_INSTANCES),
    )?;

    // Gas BEFORE backend (scheduled — never wall-time / GPU timers).
    let gas_units = proof_instance_verify_gas_units(proof_bytes.len(), instances_bytes.len());
    let gas_info = GasInfo::with_cost(
        data.gas_config
            .halo2_proof_instance_verify_cost
            .total_cost(gas_units)?,
    );
    process_gas_info(data, &mut store, gas_info)?;

    let vk = load_verifying_key_for_zkid(data, &mut store, zkid as u64)?;
    let i = prepare_instances_for_vk(&vk, instances_bytes.as_slice())?;
    let p = zk_cosmwasm::Proof::new(proof_bytes);

    // Backend dispatch: CPU golden always; feature `gpu` may select GpuBackend
    // (scaffolding falls back to CPU). Gas already charged above — never from
    // device timers. Pin/LRU unchanged (load ≠ pin).
    // See docs/research/gpu-accel/DESIGN-G1-verifier-backend.md
    let backend = zk_cosmwasm::select_backend();

    // D4: format/parse errors → VmError; crypto false → Ok(1); true → Ok(0).
    match backend.verify(&vk, &p, std::slice::from_ref(&i)) {
        Ok(_) => Ok(0),
        Err(e) if e.is_verify_failed() => Ok(1),
        Err(e) => Err(VmError::zk_err(e)),
    }
}

/// Path A **batch** proof verification — sibling of [`do_proof_instance_verify`].
///
/// Mirrors `ed25519_batch_verify` section encoding:
/// - `zkids_ptr`: region of section-encoded zkid payloads (canonical: 8-byte LE `u64`;
///   also accepts 4-byte LE `u32` for parity with the single-proof import).
/// - `proofs_ptr`: section-encoded proof byte slices.
/// - `instances_ptr`: section-encoded public-input byte slices.
///
/// Lengths of the three section lists must match. Empty batch → `Ok(0)` (all vacuously valid).
///
/// **Gas (scheduled, before backend):** reuses `GasConfig::halo2_proof_instance_verify_cost`.
/// - Empty batch: **no extra verify gas** beyond `host_call_cost` (no items to schedule).
/// - Non-empty: **sum** of per-item `total_cost(item_units)` so DoS cost ≥ sequential singles
///   (each item pays base + per_item × units; units = same formula as single verify).
/// Gas is identical for CPU/GPU backends; never wall-time.
///
/// Dispatches to `select_backend().batch_verify(...)` (`CpuBackend` golden; `GpuBackend` stub OK).
/// See docs/research/gpu-accel/DESIGN-G1-verifier-backend.md §5 / §8.
#[cfg(feature = "zk")]
pub fn do_proof_instance_batch_verify<
    A: BackendApi + 'static,
    S: Storage + 'static,
    Q: Querier + 'static,
>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    zkids_ptr: u32,
    proofs_ptr: u32,
    instances_ptr: u32,
) -> VmResult<u32> {
    let (data, mut store) = env.data_and_store_mut();
    charge_host_call_gas(data, &mut store)?;

    let zkids_raw = read_region(
        data,
        &mut store,
        zkids_ptr,
        (8 + 4) * MAX_COUNT_PROOF_INSTANCE_BATCH,
    )?;
    let proofs_raw = read_region(
        data,
        &mut store,
        proofs_ptr,
        (MAX_LENGTH_PROOF + 4) * MAX_COUNT_PROOF_INSTANCE_BATCH,
    )?;
    let instances_raw = read_region(
        data,
        &mut store,
        instances_ptr,
        (MAX_LENGTH_INSTANCES + 4) * MAX_COUNT_PROOF_INSTANCE_BATCH,
    )?;

    let zkid_secs = decode_sections(&zkids_raw)?;
    let proof_secs = decode_sections(&proofs_raw)?;
    let instance_secs = decode_sections(&instances_raw)?;

    if zkid_secs.len() != proof_secs.len() || proof_secs.len() != instance_secs.len() {
        return Err(VmError::generic_err(format!(
            "proof_instance_batch_verify length mismatch: zkids={} proofs={} instances={}",
            zkid_secs.len(),
            proof_secs.len(),
            instance_secs.len()
        )));
    }
    if zkid_secs.len() > MAX_COUNT_PROOF_INSTANCE_BATCH {
        return Err(VmError::generic_err(format!(
            "proof_instance_batch_verify batch too large: {} > {}",
            zkid_secs.len(),
            MAX_COUNT_PROOF_INSTANCE_BATCH
        )));
    }

    // Gas BEFORE any VK load / backend work (scheduled — never wall-time).
    // Empty: host_call already charged; no per-item schedule. Non-empty: sum of
    // per-item costs (parity with n sequential `proof_instance_verify` calls).
    if !zkid_secs.is_empty() {
        let gas_cost = &data.gas_config.halo2_proof_instance_verify_cost;
        let mut total = 0u64;
        for (proof, inst) in proof_secs.iter().zip(instance_secs.iter()) {
            let units = proof_instance_verify_gas_units(proof.len(), inst.len());
            let item = gas_cost.total_cost(units)?;
            total = total.checked_add(item).ok_or_else(VmError::gas_depletion)?;
        }
        process_gas_info(data, &mut store, GasInfo::with_cost(total))?;
    }

    if zkid_secs.is_empty() {
        return Ok(0);
    }

    // Parse zkids and materialize owned proof/instance buffers for batch_verify lifetimes.
    let mut zkids: Vec<u64> = Vec::with_capacity(zkid_secs.len());
    for sec in &zkid_secs {
        zkids.push(parse_batch_zkid_section(sec)?);
    }

    // Load VKs (local cache for repeated zkid in one call).
    let mut vk_cache: std::collections::HashMap<u64, zk_cosmwasm::AnyVerifyingKey> =
        std::collections::HashMap::new();
    let mut vks: Vec<zk_cosmwasm::AnyVerifyingKey> = Vec::with_capacity(zkids.len());
    for &zkid in &zkids {
        if let Some(vk) = vk_cache.get(&zkid) {
            vks.push(vk.clone());
        } else {
            let vk = load_verifying_key_for_zkid(data, &mut store, zkid)?;
            vk_cache.insert(zkid, vk.clone());
            vks.push(vk);
        }
    }

    let proofs: Vec<zk_cosmwasm::Proof> = proof_secs
        .iter()
        .map(|p| zk_cosmwasm::Proof::new(p.to_vec()))
        .collect();

    let mut instances: Vec<zk_cosmwasm::AnyInstance> = Vec::with_capacity(instance_secs.len());
    for (vk, inst_bytes) in vks.iter().zip(instance_secs.iter()) {
        instances.push(prepare_instances_for_vk(vk, inst_bytes)?);
    }

    // One-element slices per item (VerifyItem wants &[AnyInstance]).
    let instance_slices: Vec<[zk_cosmwasm::AnyInstance; 1]> =
        instances.into_iter().map(|i| [i]).collect();

    let items: Vec<zk_cosmwasm::VerifyItem<'_>> = vks
        .iter()
        .zip(proofs.iter())
        .zip(instance_slices.iter())
        .map(|((vk, proof), inst)| zk_cosmwasm::VerifyItem {
            vk,
            proof,
            instances: inst.as_slice(),
        })
        .collect();

    let backend = zk_cosmwasm::select_backend();
    match backend.batch_verify(&items) {
        Ok(()) => Ok(0),
        Err(e) if e.is_verify_failed() => Ok(1),
        Err(e) => Err(VmError::zk_err(e)),
    }
}

/// Canonical zkid section: 8-byte little-endian `u64`. Also accepts 4-byte LE `u32`.
#[cfg(feature = "zk")]
fn parse_batch_zkid_section(sec: &[u8]) -> VmResult<u64> {
    match sec.len() {
        8 => {
            let mut buf = [0u8; 8];
            buf.copy_from_slice(sec);
            Ok(u64::from_le_bytes(buf))
        }
        4 => {
            let mut buf = [0u8; 4];
            buf.copy_from_slice(sec);
            Ok(u32::from_le_bytes(buf) as u64)
        }
        n => Err(VmError::generic_err(format!(
            "proof_instance_batch_verify zkid section must be 4 or 8 bytes, got {n}"
        ))),
    }
}

/// Count public-input field limbs for H-05 arity check.
#[cfg(feature = "zk")]
fn instance_public_input_count(i: &zk_cosmwasm::AnyInstance) -> usize {
    match i {
        zk_cosmwasm::AnyInstance::Vesta(v) => v.get_size(),
        zk_cosmwasm::AnyInstance::Vote(v) => v.public_inputs.len(),
        #[cfg(feature = "bn254")]
        zk_cosmwasm::AnyInstance::Bn254(v) => v.i.len(),
        zk_cosmwasm::AnyInstance::Stwo(v) => v.public_input_count(),
        zk_cosmwasm::AnyInstance::Flock(v) => v.public_input_count(),
        #[cfg(feature = "halo2-kzg")]
        zk_cosmwasm::AnyInstance::Halo2Kzg(v) => v.scalars.len(),
    }
}

/// Helper: run a cosmwasm query through the instance querier and return the system result.
#[cfg(feature = "zk")]
fn query_raw<A: BackendApi + 'static, S: Storage + 'static, Q: Querier + 'static>(
    data: &Environment<A, S, Q>,
    store: &mut impl wasmer::AsStoreMut,
    request: &cosmwasm_std::QueryRequest<cosmwasm_std::Empty>,
) -> VmResult<cosmwasm_std::SystemResult<cosmwasm_std::ContractResult<cosmwasm_std::Binary>>> {
    use cosmwasm_std::to_json_vec;

    let request_bin = to_json_vec(request)
        .map_err(|e| VmError::generic_err(format!("serialize query request: {e}")))?;

    let gas_remaining = data.get_gas_left(store);
    let (result, gas_info) = data.with_querier_from_context::<_, _>(|querier| {
        Ok(querier.query_raw(&request_bin, gas_remaining))
    })?;
    process_gas_info(data, store, gas_info)?;
    // result: Result<SystemResult<ContractResult<Binary>>, BackendError>
    result.map_err(|e| VmError::backend_err(e))
}

/// Prints a debug message to console.
/// Debug printing should be disabled when used in a blockchain module.
pub fn do_debug<A: BackendApi + 'static, S: Storage + 'static, Q: Querier + 'static>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    message_ptr: u32,
) -> VmResult<()> {
    let (data, mut store) = env.data_and_store_mut();

    charge_host_call_gas(data, &mut store)?;
    let message_data = read_region(data, &mut store, message_ptr, MAX_LENGTH_DEBUG)?;

    if let Some(debug_handler) = data.debug_handler() {
        let msg = String::from_utf8_lossy(&message_data);
        let gas_remaining = data.get_gas_left(&mut store);
        debug_handler.borrow_mut()(
            &msg,
            DebugInfo {
                gas_remaining,
                __lifetime: PhantomData,
            },
        );
    }
    Ok(())
}

/// Aborts the contract and shows the given error message
pub fn do_abort<A: BackendApi + 'static, S: Storage + 'static, Q: Querier + 'static>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    message_ptr: u32,
) -> VmResult<()> {
    let (data, mut store) = env.data_and_store_mut();

    charge_host_call_gas(data, &mut store)?;

    let message_data = read_region(data, &mut store, message_ptr, MAX_LENGTH_ABORT)?;
    let string_gas_cost = GasInfo::with_cost(
        data.gas_config
            .string_from_bytes_cost
            .total_cost(message_data.len() as u64)?,
    );
    process_gas_info(data, &mut store, string_gas_cost)?;
    let msg = String::from_utf8_lossy(&message_data);
    Err(VmError::aborted(msg))
}

pub fn do_query_chain<A: BackendApi + 'static, S: Storage + 'static, Q: Querier + 'static>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    request_ptr: u32,
) -> VmResult<u32> {
    let (data, mut store) = env.data_and_store_mut();

    charge_host_call_gas(data, &mut store)?;

    let request = read_region(
        data,
        &mut store,
        request_ptr,
        MAX_LENGTH_QUERY_CHAIN_REQUEST,
    )?;

    let gas_remaining = data.get_gas_left(&mut store);
    let (result, gas_info) = data.with_querier_from_context::<_, _>(|querier| {
        Ok(querier.query_raw(&request, gas_remaining))
    })?;
    process_gas_info(data, &mut store, gas_info)?;
    let serialized = to_vec(&result?)?;
    write_to_contract(data, &mut store, &serialized)
}

#[cfg(feature = "iterator")]
pub fn do_db_scan<A: BackendApi + 'static, S: Storage + 'static, Q: Querier + 'static>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    start_ptr: u32,
    end_ptr: u32,
    order: i32,
) -> VmResult<u32> {
    let (data, mut store) = env.data_and_store_mut();

    charge_host_call_gas(data, &mut store)?;

    let start = maybe_read_region(data, &mut store, start_ptr, MAX_LENGTH_DB_KEY)?;
    let end = maybe_read_region(data, &mut store, end_ptr, MAX_LENGTH_DB_KEY)?;
    let order: Order = order
        .try_into()
        .map_err(|_| CommunicationError::invalid_order(order))?;

    let (result, gas_info) = data.with_storage_from_context::<_, _>(|store| {
        Ok(store.scan(start.as_deref(), end.as_deref(), order))
    })?;
    process_gas_info(data, &mut store, gas_info)?;
    let iterator_id = result?;
    Ok(iterator_id)
}

#[cfg(feature = "iterator")]
pub fn do_db_next<A: BackendApi + 'static, S: Storage + 'static, Q: Querier + 'static>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    iterator_id: u32,
) -> VmResult<u32> {
    let (data, mut store) = env.data_and_store_mut();

    charge_host_call_gas(data, &mut store)?;

    let (result, gas_info) =
        data.with_storage_from_context::<_, _>(|store| Ok(store.next(iterator_id)))?;

    process_gas_info(data, &mut store, gas_info)?;

    // Empty key will later be treated as _no more element_.
    let (key, value) = result?.unwrap_or_else(|| (Vec::<u8>::new(), Vec::<u8>::new()));

    let out_data = encode_sections(&[key, value])?;
    write_to_contract(data, &mut store, &out_data)
}

#[cfg(feature = "iterator")]
pub fn do_db_next_key<A: BackendApi + 'static, S: Storage + 'static, Q: Querier + 'static>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    iterator_id: u32,
) -> VmResult<u32> {
    let (data, mut store) = env.data_and_store_mut();

    charge_host_call_gas(data, &mut store)?;

    let (result, gas_info) =
        data.with_storage_from_context::<_, _>(|store| Ok(store.next_key(iterator_id)))?;

    process_gas_info(data, &mut store, gas_info)?;

    let key = match result? {
        Some(key) => key,
        None => return Ok(0),
    };

    write_to_contract(data, &mut store, &key)
}

#[cfg(feature = "iterator")]
pub fn do_db_next_value<A: BackendApi + 'static, S: Storage + 'static, Q: Querier + 'static>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    iterator_id: u32,
) -> VmResult<u32> {
    let (data, mut store) = env.data_and_store_mut();

    charge_host_call_gas(data, &mut store)?;

    let (result, gas_info) =
        data.with_storage_from_context::<_, _>(|store| Ok(store.next_value(iterator_id)))?;

    process_gas_info(data, &mut store, gas_info)?;

    let value = match result? {
        Some(value) => value,
        None => return Ok(0),
    };

    write_to_contract(data, &mut store, &value)
}

/// Creates a Region in the contract, writes the given data to it and returns the memory location
fn write_to_contract<A: BackendApi + 'static, S: Storage + 'static, Q: Querier + 'static>(
    data: &Environment<A, S, Q>,
    store: &mut impl AsStoreMut,
    input: &[u8],
) -> VmResult<u32> {
    let out_size = to_u32(input.len())?;
    let result = data.call_function1(store, "allocate", &[out_size.into()])?;
    let target_ptr = ref_to_u32(&result)?;
    if target_ptr == 0 {
        return Err(CommunicationError::zero_address().into());
    }
    write_region(data, &mut store.as_store_mut(), target_ptr, input)?;
    Ok(target_ptr)
}

/// Returns the data shifted by 32 bits towards the most significant bit.
///
/// This is independent of endianness. But to get the idea, it would be
/// `data || 0x00000000` in big endian representation.
#[inline]
fn to_high_half(data: u32) -> u64 {
    // See https://stackoverflow.com/a/58956419/2013738 to understand
    // why this is endianness agnostic.
    (data as u64) << 32
}

/// Returns the data copied to the 4 least significant bytes.
///
/// This is independent of endianness. But to get the idea, it would be
/// `0x00000000 || data` in big endian representation.
#[inline]
fn to_low_half(data: u32) -> u64 {
    data.into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use cosmwasm_std::{
        coin, coins, from_json, BalanceResponse, BankQuery, Binary, Empty, QueryRequest,
        SystemError, SystemResult, WasmQuery,
    };
    use hex_literal::hex;
    use std::ptr::NonNull;
    use wasmer::{imports, Function, FunctionEnv, Instance as WasmerInstance, Store};

    use crate::size::Size;
    use crate::testing::{MockApi, MockQuerier, MockStorage};
    use crate::wasm_backend::compile_module;

    static HACKATOM: &[u8] = include_bytes!("../testdata/hackatom.wasm");

    // prepared data
    const KEY1: &[u8] = b"ant";
    const VALUE1: &[u8] = b"insect";
    const KEY2: &[u8] = b"tree";
    const VALUE2: &[u8] = b"plant";

    // this account has some coins
    const INIT_ADDR: &str = "someone";
    const INIT_AMOUNT: u128 = 500;
    const INIT_DENOM: &str = "TOKEN";

    const TESTING_GAS_LIMIT: u64 = 1_000_000_000; // ~1ms
    /// Path A BN254/halo2 `proof_instance_verify` unit tests only.
    /// Production schedule (docs/ZK-VERIFY-GAS.md): square ≈ base 2.7e9 + per_item 2e8 × units
    /// ≈ 3.3e9 per verify. Cold-path e2e issues multiple verifies; keep headroom.
    /// Does **not** change production `GasConfig` / schedule economics.
    const TESTING_ZK_VERIFY_GAS_LIMIT: u64 = 20_000_000_000; // ~20ms
    const TESTING_MEMORY_LIMIT: Option<Size> = Some(Size::mebi(16));

    const ECDSA_P256K1_HASH_HEX: &str =
        "5ae8317d34d1e595e3fa7247db80c0af4320cce1116de187f8f7e2e099c0d8d0";
    const ECDSA_P256K1_SIG_HEX: &str = "207082eb2c3dfa0b454e0906051270ba4074ac93760ba9e7110cd9471475111151eb0dbbc9920e72146fb564f99d039802bf6ef2561446eb126ef364d21ee9c4";
    const ECDSA_P256K1_PUBKEY_HEX: &str = "04051c1ee2190ecfb174bfe4f90763f2b4ff7517b70a2aec1876ebcfd644c4633fb03f3cfbd94b1f376e34592d9d41ccaf640bb751b00a1fadeb0c01157769eb73";
    const ECDSA_P256R1_HASH_HEX: &str =
        "b804cf88af0c2eff8bbbfb3660ebb3294138e9d3ebd458884e19818061dacff0";
    const ECDSA_P256R1_SIG_HEX: &str = "35fb60f5ca0f3ca08542fb3cc641c8263a2cab7a90ee6a5e1583fac2bb6f6bd1ee59d81bc9db1055cc0ed97b159d8784af04e98511d0a9a407b99bb292572e96";
    const ECDSA_P256R1_PUBKEY_HEX: &str = "0474ccd8a62fba0e667c50929a53f78c21b8ff0c3c737b0b40b1750b2302b0bde829074e21f3a0ef88b9efdf10d06aa4c295cc1671f758ca0e4cd108803d0f2614";

    const EDDSA_MSG_HEX: &str = "";
    const EDDSA_SIG_HEX: &str = "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b";
    const EDDSA_PUBKEY_HEX: &str =
        "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";

    fn make_instance(
        api: MockApi,
    ) -> (
        FunctionEnv<Environment<MockApi, MockStorage, MockQuerier>>,
        Store,
        Box<WasmerInstance>,
    ) {
        make_instance_with_gas_limit(api, TESTING_GAS_LIMIT)
    }

    fn make_instance_with_gas_limit(
        api: MockApi,
        gas_limit: u64,
    ) -> (
        FunctionEnv<Environment<MockApi, MockStorage, MockQuerier>>,
        Store,
        Box<WasmerInstance>,
    ) {
        let env = Environment::new(api, gas_limit);

        let (module, engine) = compile_module(HACKATOM, TESTING_MEMORY_LIMIT).unwrap();
        let mut store = Store::new(engine);

        let fe = FunctionEnv::new(&mut store, env);

        // we need stubs for all required imports
        let import_obj = imports! {
            "env" => {
                "db_read" => Function::new_typed(&mut store, |_a: u32| -> u32 { 0 }),
                "db_write" => Function::new_typed(&mut store, |_a: u32, _b: u32| {}),
                "db_remove" => Function::new_typed(&mut store, |_a: u32| {}),
                "db_scan" => Function::new_typed(&mut store, |_a: u32, _b: u32, _c: i32| -> u32 { 0 }),
                "db_next" => Function::new_typed(&mut store, |_a: u32| -> u32 { 0 }),
                "db_next_key" => Function::new_typed(&mut store, |_a: u32| -> u32 { 0 }),
                "db_next_value" => Function::new_typed(&mut store, |_a: u32| -> u32 { 0 }),
                "query_chain" => Function::new_typed(&mut store, |_a: u32| -> u32 { 0 }),
                "addr_validate" => Function::new_typed(&mut store, |_a: u32| -> u32 { 0 }),
                "addr_canonicalize" => Function::new_typed(&mut store, |_a: u32, _b: u32| -> u32 { 0 }),
                "addr_humanize" => Function::new_typed(&mut store, |_a: u32, _b: u32| -> u32 { 0 }),
                "bls12_381_aggregate_g1" => Function::new_typed(&mut store, |_a: u32, _b: u32| -> u32 { 0 }),
                "bls12_381_aggregate_g2" => Function::new_typed(&mut store, |_a: u32, _b: u32| -> u32 { 0 }),
                "bls12_381_pairing_equality" => Function::new_typed(&mut store, |_a: u32, _b: u32, _c: u32, _d: u32| -> u32 { 0 }),
                "bls12_381_hash_to_g1" => Function::new_typed(&mut store, |_a: u32, _b: u32, _c: u32, _d: u32| -> u32 { 0 }),
                "bls12_381_hash_to_g2" => Function::new_typed(&mut store, |_a: u32, _b: u32, _c: u32, _d: u32| -> u32 { 0 }),
                "bn254_add" => Function::new_typed(&mut store, |_a: u32, _b: u32| -> u32 { 0 }),
                "bn254_scalar_mul" => Function::new_typed(&mut store, |_a: u32, _b: u32| -> u32 { 0 }),
                "bn254_pairing_equality" => Function::new_typed(&mut store, |_a: u32| -> u32 { 0 }),
                "blake2b_256" => Function::new_typed(&mut store, |_a: u32, _b: u32| -> u32 { 0 }),
                "blake3_256" => Function::new_typed(&mut store, |_a: u32, _b: u32| -> u32 { 0 }),
                "poseidon_hash_pallas" => Function::new_typed(&mut store, |_a: u32, _b: u32| -> u32 { 0 }),
                "poseidon_hash_vesta" => Function::new_typed(&mut store, |_a: u32, _b: u32| -> u32 { 0 }),
                "poseidon377_hash" => Function::new_typed(&mut store, |_a: u32, _b: u32, _c: u32| -> u32 { 0 }),
                "redpallas_spendauth_verify" => Function::new_typed(&mut store, |_a: u32, _b: u32, _c: u32| -> u32 { 0 }),
                "redpallas_binding_verify" => Function::new_typed(&mut store, |_a: u32, _b: u32, _c: u32| -> u32 { 0 }),
                "redjubjub_spendauth_verify" => Function::new_typed(&mut store, |_a: u32, _b: u32, _c: u32| -> u32 { 0 }),
                "redjubjub_binding_verify" => Function::new_typed(&mut store, |_a: u32, _b: u32, _c: u32| -> u32 { 0 }),
                "secp256k1_verify" => Function::new_typed(&mut store, |_a: u32, _b: u32, _c: u32| -> u32 { 0 }),
                "secp256k1_recover_pubkey" => Function::new_typed(&mut store, |_a: u32, _b: u32, _c: u32| -> u64 { 0 }),
                "secp256r1_verify" => Function::new_typed(&mut store, |_a: u32, _b: u32, _c: u32| -> u32 { 0 }),
                "secp256r1_recover_pubkey" => Function::new_typed(&mut store, |_a: u32, _b: u32, _c: u32| -> u64 { 0 }),
                "proof_instance_verify" => Function::new_typed(&mut store, |_a: u32, _b: u32, _c: u32,_d: u32,_e: u32| -> u64 { 0 }),
                "proof_instance_batch_verify" => Function::new_typed(&mut store, |_a: u32, _b: u32, _c: u32| -> u32 { 0 }),
                "ed25519_verify" => Function::new_typed(&mut store, |_a: u32, _b: u32, _c: u32| -> u32 { 0 }),
                "ed25519_batch_verify" => Function::new_typed(&mut store, |_a: u32, _b: u32, _c: u32| -> u32 { 0 }),
                "debug" => Function::new_typed(&mut store, |_a: u32| {}),
                "abort" => Function::new_typed(&mut store, |_a: u32| {}),
            },
        };
        let wasmer_instance =
            Box::from(WasmerInstance::new(&mut store, &module, &import_obj).unwrap());
        let memory = wasmer_instance
            .exports
            .get_memory("memory")
            .unwrap()
            .clone();

        fe.as_mut(&mut store).memory = Some(memory);

        let instance_ptr = NonNull::from(wasmer_instance.as_ref());

        {
            let mut fe_mut = fe.clone().into_mut(&mut store);
            let (env, mut store) = fe_mut.data_and_store_mut();

            env.set_wasmer_instance(Some(instance_ptr));
            env.set_gas_left(&mut store, gas_limit);
            env.set_storage_readonly(false);
        }

        (fe, store, wasmer_instance)
    }

    fn leave_default_data(
        fe_mut: &mut FunctionEnvMut<Environment<MockApi, MockStorage, MockQuerier>>,
    ) {
        let (env, _store) = fe_mut.data_and_store_mut();

        // create some mock data
        let mut storage = MockStorage::new();
        storage.set(KEY1, VALUE1).0.expect("error setting");
        storage.set(KEY2, VALUE2).0.expect("error setting");
        let querier: MockQuerier<Empty> =
            MockQuerier::new(&[(INIT_ADDR, &coins(INIT_AMOUNT, INIT_DENOM))]);
        env.move_in(storage, querier);
    }

    fn write_data(
        fe_mut: &mut FunctionEnvMut<Environment<MockApi, MockStorage, MockQuerier>>,
        data: &[u8],
    ) -> u32 {
        let (env, mut store) = fe_mut.data_and_store_mut();

        let result = env
            .call_function1(&mut store, "allocate", &[(data.len() as u32).into()])
            .unwrap();
        let region_ptr = ref_to_u32(&result).unwrap();
        write_region(env, &mut store, region_ptr, data).expect("error writing");
        region_ptr
    }

    fn create_empty(
        wasmer_instance: &WasmerInstance,
        fe_mut: &mut FunctionEnvMut<Environment<MockApi, MockStorage, MockQuerier>>,
        capacity: u32,
    ) -> u32 {
        let (_, mut store) = fe_mut.data_and_store_mut();
        let allocate = wasmer_instance
            .exports
            .get_function("allocate")
            .expect("error getting function");
        let result = allocate
            .call(&mut store, &[capacity.into()])
            .expect("error calling allocate");
        ref_to_u32(&result[0]).expect("error converting result")
    }

    /// A Region reader that is just good enough for the tests in this file
    fn force_read(
        fe_mut: &mut FunctionEnvMut<Environment<MockApi, MockStorage, MockQuerier>>,
        region_ptr: u32,
    ) -> Vec<u8> {
        let (env, mut store) = fe_mut.data_and_store_mut();

        read_region(env, &mut store, region_ptr, 5000).unwrap()
    }

    #[test]
    fn do_db_read_works() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);
        leave_default_data(&mut fe_mut);

        let key_ptr = write_data(&mut fe_mut, KEY1);
        let result = do_db_read(fe_mut.as_mut(), key_ptr);
        let value_ptr = result.unwrap();
        assert!(value_ptr > 0);
        leave_default_data(&mut fe_mut);
        assert_eq!(force_read(&mut fe_mut, value_ptr), VALUE1);
    }

    #[test]
    fn do_db_read_works_for_non_existent_key() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);
        leave_default_data(&mut fe_mut);

        let key_ptr = write_data(&mut fe_mut, b"I do not exist in storage");
        let result = do_db_read(fe_mut, key_ptr);
        assert_eq!(result.unwrap(), 0);
    }

    #[test]
    fn do_db_read_fails_for_large_key() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);
        leave_default_data(&mut fe_mut);

        let key_ptr = write_data(&mut fe_mut, &vec![7u8; 300 * 1024]);
        let result = do_db_read(fe_mut, key_ptr);
        match result.unwrap_err() {
            VmError::CommunicationErr {
                source: CommunicationError::RegionLengthTooBig { length, .. },
                ..
            } => assert_eq!(length, 300 * 1024),
            e => panic!("Unexpected error: {e:?}"),
        }
    }

    #[test]
    fn do_db_write_works() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let key_ptr = write_data(&mut fe_mut, b"new storage key");
        let value_ptr = write_data(&mut fe_mut, b"new value");

        leave_default_data(&mut fe_mut);

        do_db_write(fe_mut.as_mut(), key_ptr, value_ptr).unwrap();

        let val = fe_mut
            .data()
            .with_storage_from_context::<_, _>(|store| {
                Ok(store
                    .get(b"new storage key")
                    .0
                    .expect("error getting value"))
            })
            .unwrap();
        assert_eq!(val, Some(b"new value".to_vec()));
    }

    #[test]
    fn do_db_write_can_override() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let key_ptr = write_data(&mut fe_mut, KEY1);
        let value_ptr = write_data(&mut fe_mut, VALUE2);

        leave_default_data(&mut fe_mut);

        do_db_write(fe_mut.as_mut(), key_ptr, value_ptr).unwrap();

        let val = fe_mut
            .data()
            .with_storage_from_context::<_, _>(|store| {
                Ok(store.get(KEY1).0.expect("error getting value"))
            })
            .unwrap();
        assert_eq!(val, Some(VALUE2.to_vec()));
    }

    #[test]
    fn do_db_write_works_for_empty_value() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let key_ptr = write_data(&mut fe_mut, b"new storage key");
        let value_ptr = write_data(&mut fe_mut, b"");

        leave_default_data(&mut fe_mut);

        do_db_write(fe_mut.as_mut(), key_ptr, value_ptr).unwrap();

        let val = fe_mut
            .data()
            .with_storage_from_context::<_, _>(|store| {
                Ok(store
                    .get(b"new storage key")
                    .0
                    .expect("error getting value"))
            })
            .unwrap();
        assert_eq!(val, Some(b"".to_vec()));
    }

    #[test]
    fn do_db_write_fails_for_large_key() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        const KEY_SIZE: usize = 300 * 1024;
        let key_ptr = write_data(&mut fe_mut, &vec![4u8; KEY_SIZE]);
        let value_ptr = write_data(&mut fe_mut, b"new value");

        leave_default_data(&mut fe_mut);

        let result = do_db_write(fe_mut, key_ptr, value_ptr);
        assert_eq!(result.unwrap_err().to_string(), format!("Generic error: Key too big. Tried to write {KEY_SIZE} bytes to storage, limit is {MAX_LENGTH_DB_KEY}."));
    }

    #[test]
    fn do_db_write_fails_for_large_value() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        const VAL_SIZE: usize = 300 * 1024;
        let key_ptr = write_data(&mut fe_mut, b"new storage key");
        let value_ptr = write_data(&mut fe_mut, &vec![5u8; VAL_SIZE]);

        leave_default_data(&mut fe_mut);

        let result = do_db_write(fe_mut, key_ptr, value_ptr);
        assert_eq!(result.unwrap_err().to_string(), format!("Generic error: Value too big. Tried to write {VAL_SIZE} bytes to storage, limit is {MAX_LENGTH_DB_VALUE}."));
    }

    #[test]
    fn do_db_write_is_prohibited_in_readonly_contexts() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let key_ptr = write_data(&mut fe_mut, b"new storage key");
        let value_ptr = write_data(&mut fe_mut, b"new value");

        leave_default_data(&mut fe_mut);
        fe_mut.data().set_storage_readonly(true);

        let result = do_db_write(fe_mut, key_ptr, value_ptr);
        match result.unwrap_err() {
            VmError::WriteAccessDenied { .. } => {}
            e => panic!("Unexpected error: {e:?}"),
        }
    }

    #[test]
    fn do_db_remove_works() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let existing_key = KEY1;
        let key_ptr = write_data(&mut fe_mut, existing_key);

        leave_default_data(&mut fe_mut);

        fe_mut
            .data()
            .with_storage_from_context::<_, _>(|store| {
                println!("{store:?}");
                Ok(())
            })
            .unwrap();

        do_db_remove(fe_mut.as_mut(), key_ptr).unwrap();

        fe_mut
            .data()
            .with_storage_from_context::<_, _>(|store| {
                println!("{store:?}");
                Ok(())
            })
            .unwrap();

        let value = fe_mut
            .data()
            .with_storage_from_context::<_, _>(|store| {
                Ok(store.get(existing_key).0.expect("error getting value"))
            })
            .unwrap();
        assert_eq!(value, None);
    }

    #[test]
    fn do_db_remove_works_for_non_existent_key() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let non_existent_key = b"I do not exist";
        let key_ptr = write_data(&mut fe_mut, non_existent_key);

        leave_default_data(&mut fe_mut);

        // Note: right now we cannot differentiate between an existent and a non-existent key
        do_db_remove(fe_mut.as_mut(), key_ptr).unwrap();

        let value = fe_mut
            .data()
            .with_storage_from_context::<_, _>(|store| {
                Ok(store.get(non_existent_key).0.expect("error getting value"))
            })
            .unwrap();
        assert_eq!(value, None);
    }

    #[test]
    fn do_db_remove_fails_for_large_key() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let key_ptr = write_data(&mut fe_mut, &vec![26u8; 300 * 1024]);

        leave_default_data(&mut fe_mut);

        let result = do_db_remove(fe_mut, key_ptr);
        match result.unwrap_err() {
            VmError::CommunicationErr {
                source:
                    CommunicationError::RegionLengthTooBig {
                        length, max_length, ..
                    },
                ..
            } => {
                assert_eq!(length, 300 * 1024);
                assert_eq!(max_length, MAX_LENGTH_DB_KEY);
            }
            err => panic!("unexpected error: {err:?}"),
        };
    }

    #[test]
    fn do_db_remove_is_prohibited_in_readonly_contexts() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let key_ptr = write_data(&mut fe_mut, b"a storage key");

        leave_default_data(&mut fe_mut);
        fe_mut.data().set_storage_readonly(true);

        let result = do_db_remove(fe_mut, key_ptr);
        match result.unwrap_err() {
            VmError::WriteAccessDenied { .. } => {}
            e => panic!("Unexpected error: {e:?}"),
        }
    }

    #[test]
    fn do_addr_validate_works() {
        let api = MockApi::default().with_prefix("osmo");
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let source_ptr1 = write_data(&mut fe_mut, b"osmo186kh7c0k0gh4ww0wh4jqc4yhzu7n7dhswe845d");
        let source_ptr2 = write_data(&mut fe_mut, b"osmo18enxpg25jc4zkwe7w00yneva0vztwuex3rtv8t");

        let res = do_addr_validate(fe_mut.as_mut(), source_ptr1).unwrap();
        assert_eq!(res, 0);
        let res = do_addr_validate(fe_mut.as_mut(), source_ptr2).unwrap();
        assert_eq!(res, 0);
    }

    #[test]
    fn do_addr_validate_reports_invalid_input_back_to_contract() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let source_ptr1 = write_data(&mut fe_mut, b"cosmwasm\x80o"); // invalid UTF-8 (cosmwasm�o)
        let source_ptr2 = write_data(&mut fe_mut, b""); // empty
        let source_ptr3 = write_data(
            &mut fe_mut,
            b"cosmwasm1h34LMPYwh4upnjdg90cjf4j70aee6z8qqfspugamjp42e4q28kqs8s7vcp",
        ); // Not normalized. The definition of normalized is chain-dependent but the MockApi disallows mixed case.

        let res = do_addr_validate(fe_mut.as_mut(), source_ptr1).unwrap();
        assert_ne!(res, 0);
        let err = String::from_utf8(force_read(&mut fe_mut, res)).unwrap();
        assert_eq!(err, "Input is not valid UTF-8");

        let res = do_addr_validate(fe_mut.as_mut(), source_ptr2).unwrap();
        assert_ne!(res, 0);
        let err = String::from_utf8(force_read(&mut fe_mut, res)).unwrap();
        assert_eq!(err, "Input is empty");

        let res = do_addr_validate(fe_mut.as_mut(), source_ptr3).unwrap();
        assert_ne!(res, 0);
        let err = String::from_utf8(force_read(&mut fe_mut, res)).unwrap();
        assert_eq!(err, "Error decoding bech32");
    }

    #[test]
    fn do_addr_validate_fails_for_broken_backend() {
        let api = MockApi::new_failing("Temporarily unavailable");
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let source_ptr = write_data(&mut fe_mut, b"foo");

        leave_default_data(&mut fe_mut);

        let result = do_addr_validate(fe_mut, source_ptr);
        match result.unwrap_err() {
            VmError::BackendErr {
                source: BackendError::Unknown { msg, .. },
                ..
            } => assert_eq!(msg, "Temporarily unavailable"),
            err => panic!("Incorrect error returned: {err:?}"),
        }
    }

    #[test]
    fn do_addr_validate_fails_for_large_inputs() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let source_ptr = write_data(&mut fe_mut, &[61; 333]);

        leave_default_data(&mut fe_mut);

        let result = do_addr_validate(fe_mut, source_ptr);
        match result.unwrap_err() {
            VmError::CommunicationErr {
                source:
                    CommunicationError::RegionLengthTooBig {
                        length, max_length, ..
                    },
                ..
            } => {
                assert_eq!(length, 333);
                assert_eq!(max_length, 256);
            }
            err => panic!("Incorrect error returned: {err:?}"),
        }
    }

    const CANONICAL_ADDRESS_BUFFER_LENGTH: u32 = 64;

    #[test]
    fn do_addr_canonicalize_works() {
        let api = MockApi::default();
        let (fe, mut store, instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let source_ptr = write_data(
            &mut fe_mut,
            b"cosmwasm1h34lmpywh4upnjdg90cjf4j70aee6z8qqfspugamjp42e4q28kqs8s7vcp",
        );
        let dest_ptr = create_empty(&instance, &mut fe_mut, CANONICAL_ADDRESS_BUFFER_LENGTH);

        leave_default_data(&mut fe_mut);

        let res = do_addr_canonicalize(fe_mut.as_mut(), source_ptr, dest_ptr).unwrap();
        assert_eq!(res, 0);
        let data = force_read(&mut fe_mut, dest_ptr);
        assert_eq!(data.len(), 32);
    }

    #[test]
    fn do_addr_canonicalize_reports_invalid_input_back_to_contract() {
        let api = MockApi::default();
        let (fe, mut store, instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let source_ptr1 = write_data(&mut fe_mut, b"cosmwasm\x80o"); // invalid UTF-8 (cosmwasm�o)
        let source_ptr2 = write_data(&mut fe_mut, b""); // empty
        let dest_ptr = create_empty(&instance, &mut fe_mut, 70);

        leave_default_data(&mut fe_mut);

        let res = do_addr_canonicalize(fe_mut.as_mut(), source_ptr1, dest_ptr).unwrap();
        assert_ne!(res, 0);
        let err = String::from_utf8(force_read(&mut fe_mut, res)).unwrap();
        assert_eq!(err, "Input is not valid UTF-8");

        let res = do_addr_canonicalize(fe_mut.as_mut(), source_ptr2, dest_ptr).unwrap();
        assert_ne!(res, 0);
        let err = String::from_utf8(force_read(&mut fe_mut, res)).unwrap();
        assert_eq!(err, "Input is empty");
    }

    #[test]
    fn do_addr_canonicalize_fails_for_broken_backend() {
        let api = MockApi::new_failing("Temporarily unavailable");
        let (fe, mut store, instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let source_ptr = write_data(&mut fe_mut, b"foo");
        let dest_ptr = create_empty(&instance, &mut fe_mut, 7);

        leave_default_data(&mut fe_mut);

        let result = do_addr_canonicalize(fe_mut.as_mut(), source_ptr, dest_ptr);
        match result.unwrap_err() {
            VmError::BackendErr {
                source: BackendError::Unknown { msg, .. },
                ..
            } => assert_eq!(msg, "Temporarily unavailable"),
            err => panic!("Incorrect error returned: {err:?}"),
        }
    }

    #[test]
    fn do_addr_canonicalize_fails_for_large_inputs() {
        let api = MockApi::default();
        let (fe, mut store, instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let source_ptr = write_data(&mut fe_mut, &[61; 333]);
        let dest_ptr = create_empty(&instance, &mut fe_mut, 8);

        leave_default_data(&mut fe_mut);

        let result = do_addr_canonicalize(fe_mut.as_mut(), source_ptr, dest_ptr);
        match result.unwrap_err() {
            VmError::CommunicationErr {
                source:
                    CommunicationError::RegionLengthTooBig {
                        length, max_length, ..
                    },
                ..
            } => {
                assert_eq!(length, 333);
                assert_eq!(max_length, 256);
            }
            err => panic!("Incorrect error returned: {err:?}"),
        }
    }

    #[test]
    fn do_addr_canonicalize_fails_for_small_destination_region() {
        let api = MockApi::default().with_prefix("osmo");
        let (fe, mut store, instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let source_ptr = write_data(&mut fe_mut, b"osmo18enxpg25jc4zkwe7w00yneva0vztwuex3rtv8t");
        let dest_ptr = create_empty(&instance, &mut fe_mut, 7);

        leave_default_data(&mut fe_mut);

        let result = do_addr_canonicalize(fe_mut, source_ptr, dest_ptr);
        match result.unwrap_err() {
            VmError::CommunicationErr {
                source: CommunicationError::RegionTooSmall { size, required, .. },
                ..
            } => {
                assert_eq!(size, 7);
                assert_eq!(required, 20);
            }
            err => panic!("Incorrect error returned: {err:?}"),
        }
    }

    #[test]
    fn do_addr_humanize_works() {
        let api = MockApi::default();
        let (fe, mut store, instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let source_data = vec![0x22; CANONICAL_ADDRESS_BUFFER_LENGTH as usize];
        let source_ptr = write_data(&mut fe_mut, &source_data);
        let dest_ptr = create_empty(&instance, &mut fe_mut, 118);

        leave_default_data(&mut fe_mut);

        let error_ptr = do_addr_humanize(fe_mut.as_mut(), source_ptr, dest_ptr).unwrap();
        assert_eq!(error_ptr, 0);
        assert_eq!(force_read(&mut fe_mut, dest_ptr), b"cosmwasm1yg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygsegeksq");
    }

    #[test]
    fn do_addr_humanize_reports_invalid_input_back_to_contract() {
        let api = MockApi::default();
        let (fe, mut store, instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let source_ptr = write_data(&mut fe_mut, b""); // too short
        let dest_ptr = create_empty(&instance, &mut fe_mut, 70);

        leave_default_data(&mut fe_mut);

        let res = do_addr_humanize(fe_mut.as_mut(), source_ptr, dest_ptr).unwrap();
        assert_ne!(res, 0);
        let err = String::from_utf8(force_read(&mut fe_mut, res)).unwrap();
        assert_eq!(err, "Invalid canonical address length");
    }

    #[test]
    fn do_addr_humanize_fails_for_broken_backend() {
        let api = MockApi::new_failing("Temporarily unavailable");
        let (fe, mut store, instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let source_ptr = write_data(&mut fe_mut, b"foo\0\0\0\0\0");
        let dest_ptr = create_empty(&instance, &mut fe_mut, 70);

        leave_default_data(&mut fe_mut);

        let result = do_addr_humanize(fe_mut, source_ptr, dest_ptr);
        match result.unwrap_err() {
            VmError::BackendErr {
                source: BackendError::Unknown { msg, .. },
                ..
            } => assert_eq!(msg, "Temporarily unavailable"),
            err => panic!("Incorrect error returned: {err:?}"),
        };
    }

    #[test]
    fn do_addr_humanize_fails_for_input_too_long() {
        let api = MockApi::default();
        let (fe, mut store, instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let source_ptr = write_data(&mut fe_mut, &[61; 65]);
        let dest_ptr = create_empty(&instance, &mut fe_mut, 70);

        leave_default_data(&mut fe_mut);

        let result = do_addr_humanize(fe_mut, source_ptr, dest_ptr);
        match result.unwrap_err() {
            VmError::CommunicationErr {
                source:
                    CommunicationError::RegionLengthTooBig {
                        length, max_length, ..
                    },
                ..
            } => {
                assert_eq!(length, 65);
                assert_eq!(max_length, 64);
            }
            err => panic!("Incorrect error returned: {err:?}"),
        }
    }

    #[test]
    fn do_addr_humanize_fails_for_destination_region_too_small() {
        let api = MockApi::default();
        let (fe, mut store, instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let source_data = vec![0x22; CANONICAL_ADDRESS_BUFFER_LENGTH as usize];
        let source_ptr = write_data(&mut fe_mut, &source_data);
        let dest_ptr = create_empty(&instance, &mut fe_mut, 2);

        leave_default_data(&mut fe_mut);

        let result = do_addr_humanize(fe_mut, source_ptr, dest_ptr);
        match result.unwrap_err() {
            VmError::CommunicationErr {
                source: CommunicationError::RegionTooSmall { size, required, .. },
                ..
            } => {
                assert_eq!(size, 2);
                assert_eq!(required, 118);
            }
            err => panic!("Incorrect error returned: {err:?}"),
        }
    }

    #[test]
    fn do_secp256k1_verify_works() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let hash = hex::decode(ECDSA_P256K1_HASH_HEX).unwrap();
        let hash_ptr = write_data(&mut fe_mut, &hash);
        let sig = hex::decode(ECDSA_P256K1_SIG_HEX).unwrap();
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let pubkey = hex::decode(ECDSA_P256K1_PUBKEY_HEX).unwrap();
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        assert_eq!(
            do_secp256k1_verify(fe_mut, hash_ptr, sig_ptr, pubkey_ptr).unwrap(),
            0
        );
    }

    #[test]
    fn do_secp256k1_verify_wrong_hash_verify_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let mut hash = hex::decode(ECDSA_P256K1_HASH_HEX).unwrap();
        // alter hash
        hash[0] ^= 0x01;
        let hash_ptr = write_data(&mut fe_mut, &hash);
        let sig = hex::decode(ECDSA_P256K1_SIG_HEX).unwrap();
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let pubkey = hex::decode(ECDSA_P256K1_PUBKEY_HEX).unwrap();
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        assert_eq!(
            do_secp256k1_verify(fe_mut, hash_ptr, sig_ptr, pubkey_ptr).unwrap(),
            1
        );
    }

    #[test]
    fn do_secp256k1_verify_larger_hash_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let mut hash = hex::decode(ECDSA_P256K1_HASH_HEX).unwrap();
        // extend / break hash
        hash.push(0x00);
        let hash_ptr = write_data(&mut fe_mut, &hash);
        let sig = hex::decode(ECDSA_P256K1_SIG_HEX).unwrap();
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let pubkey = hex::decode(ECDSA_P256K1_PUBKEY_HEX).unwrap();
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        let result = do_secp256k1_verify(fe_mut, hash_ptr, sig_ptr, pubkey_ptr);
        match result.unwrap_err() {
            VmError::CommunicationErr {
                source: CommunicationError::RegionLengthTooBig { length, .. },
                ..
            } => assert_eq!(length, MESSAGE_HASH_MAX_LEN + 1),
            e => panic!("Unexpected error: {e:?}"),
        }
    }

    #[test]
    fn do_secp256k1_verify_shorter_hash_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let mut hash = hex::decode(ECDSA_P256K1_HASH_HEX).unwrap();
        // reduce / break hash
        hash.pop();
        let hash_ptr = write_data(&mut fe_mut, &hash);
        let sig = hex::decode(ECDSA_P256K1_SIG_HEX).unwrap();
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let pubkey = hex::decode(ECDSA_P256K1_PUBKEY_HEX).unwrap();
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        assert_eq!(
            do_secp256k1_verify(fe_mut, hash_ptr, sig_ptr, pubkey_ptr).unwrap(),
            3 // mapped InvalidHashFormat
        );
    }

    #[test]
    fn do_secp256k1_verify_wrong_sig_verify_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let hash = hex::decode(ECDSA_P256K1_HASH_HEX).unwrap();
        let hash_ptr = write_data(&mut fe_mut, &hash);
        let mut sig = hex::decode(ECDSA_P256K1_SIG_HEX).unwrap();
        // alter sig
        sig[0] ^= 0x01;
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let pubkey = hex::decode(ECDSA_P256K1_PUBKEY_HEX).unwrap();
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        assert_eq!(
            do_secp256k1_verify(fe_mut, hash_ptr, sig_ptr, pubkey_ptr).unwrap(),
            1
        );
    }

    #[test]
    fn do_secp256k1_verify_larger_sig_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let hash = hex::decode(ECDSA_P256K1_HASH_HEX).unwrap();
        let hash_ptr = write_data(&mut fe_mut, &hash);
        let mut sig = hex::decode(ECDSA_P256K1_SIG_HEX).unwrap();
        // extend / break sig
        sig.push(0x00);
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let pubkey = hex::decode(ECDSA_P256K1_PUBKEY_HEX).unwrap();
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        let result = do_secp256k1_verify(fe_mut, hash_ptr, sig_ptr, pubkey_ptr);
        match result.unwrap_err() {
            VmError::CommunicationErr {
                source: CommunicationError::RegionLengthTooBig { length, .. },
                ..
            } => assert_eq!(length, ECDSA_SIGNATURE_LEN + 1),
            e => panic!("Unexpected error: {e:?}"),
        }
    }

    #[test]
    fn do_secp256k1_verify_shorter_sig_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let hash = hex::decode(ECDSA_P256K1_HASH_HEX).unwrap();
        let hash_ptr = write_data(&mut fe_mut, &hash);
        let mut sig = hex::decode(ECDSA_P256K1_SIG_HEX).unwrap();
        // reduce / break sig
        sig.pop();
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let pubkey = hex::decode(ECDSA_P256K1_PUBKEY_HEX).unwrap();
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        assert_eq!(
            do_secp256k1_verify(fe_mut, hash_ptr, sig_ptr, pubkey_ptr).unwrap(),
            4 // mapped InvalidSignatureFormat
        )
    }

    #[test]
    fn do_secp256k1_verify_wrong_pubkey_format_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let hash = hex::decode(ECDSA_P256K1_HASH_HEX).unwrap();
        let hash_ptr = write_data(&mut fe_mut, &hash);
        let sig = hex::decode(ECDSA_P256K1_SIG_HEX).unwrap();
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let mut pubkey = hex::decode(ECDSA_P256K1_PUBKEY_HEX).unwrap();
        // alter pubkey format
        pubkey[0] ^= 0x01;
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        assert_eq!(
            do_secp256k1_verify(fe_mut, hash_ptr, sig_ptr, pubkey_ptr).unwrap(),
            5 // mapped InvalidPubkeyFormat
        )
    }

    #[test]
    fn do_secp256k1_verify_wrong_pubkey_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let hash = hex::decode(ECDSA_P256K1_HASH_HEX).unwrap();
        let hash_ptr = write_data(&mut fe_mut, &hash);
        let sig = hex::decode(ECDSA_P256K1_SIG_HEX).unwrap();
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let mut pubkey = hex::decode(ECDSA_P256K1_PUBKEY_HEX).unwrap();
        // alter pubkey
        pubkey[1] ^= 0x01;
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        assert_eq!(
            do_secp256k1_verify(fe_mut, hash_ptr, sig_ptr, pubkey_ptr).unwrap(),
            10 // mapped GenericErr
        )
    }

    #[test]
    fn do_secp256k1_verify_larger_pubkey_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let hash = hex::decode(ECDSA_P256K1_HASH_HEX).unwrap();
        let hash_ptr = write_data(&mut fe_mut, &hash);
        let sig = hex::decode(ECDSA_P256K1_SIG_HEX).unwrap();
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let mut pubkey = hex::decode(ECDSA_P256K1_PUBKEY_HEX).unwrap();
        // extend / break pubkey
        pubkey.push(0x00);
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        let result = do_secp256k1_verify(fe_mut, hash_ptr, sig_ptr, pubkey_ptr);
        match result.unwrap_err() {
            VmError::CommunicationErr {
                source: CommunicationError::RegionLengthTooBig { length, .. },
                ..
            } => assert_eq!(length, ECDSA_PUBKEY_MAX_LEN + 1),
            e => panic!("Unexpected error: {e:?}"),
        }
    }

    #[test]
    fn do_secp256k1_verify_shorter_pubkey_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let hash = hex::decode(ECDSA_P256K1_HASH_HEX).unwrap();
        let hash_ptr = write_data(&mut fe_mut, &hash);
        let sig = hex::decode(ECDSA_P256K1_SIG_HEX).unwrap();
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let mut pubkey = hex::decode(ECDSA_P256K1_PUBKEY_HEX).unwrap();
        // reduce / break pubkey
        pubkey.pop();
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        assert_eq!(
            do_secp256k1_verify(fe_mut, hash_ptr, sig_ptr, pubkey_ptr).unwrap(),
            5 // mapped InvalidPubkeyFormat
        )
    }

    #[test]
    fn do_secp256k1_verify_empty_pubkey_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let hash = hex::decode(ECDSA_P256K1_HASH_HEX).unwrap();
        let hash_ptr = write_data(&mut fe_mut, &hash);
        let sig = hex::decode(ECDSA_P256K1_SIG_HEX).unwrap();
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let pubkey = vec![];
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        assert_eq!(
            do_secp256k1_verify(fe_mut, hash_ptr, sig_ptr, pubkey_ptr).unwrap(),
            5 // mapped InvalidPubkeyFormat
        )
    }

    #[test]
    fn do_secp256k1_verify_wrong_data_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let hash = vec![0x22; MESSAGE_HASH_MAX_LEN];
        let hash_ptr = write_data(&mut fe_mut, &hash);
        let sig = vec![0x22; ECDSA_SIGNATURE_LEN];
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let pubkey = vec![0x04; ECDSA_PUBKEY_MAX_LEN];
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        assert_eq!(
            do_secp256k1_verify(fe_mut, hash_ptr, sig_ptr, pubkey_ptr).unwrap(),
            10 // mapped GenericErr
        )
    }

    #[test]
    fn do_secp256k1_recover_pubkey_works() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        // https://gist.github.com/webmaster128/130b628d83621a33579751846699ed15
        let hash = hex!("5ae8317d34d1e595e3fa7247db80c0af4320cce1116de187f8f7e2e099c0d8d0");
        let sig = hex!("45c0b7f8c09a9e1f1cea0c25785594427b6bf8f9f878a8af0b1abbb48e16d0920d8becd0c220f67c51217eecfd7184ef0732481c843857e6bc7fc095c4f6b788");
        let recovery_param = 1;
        let expected = hex!("044a071e8a6e10aada2b8cf39fa3b5fb3400b04e99ea8ae64ceea1a977dbeaf5d5f8c8fbd10b71ab14cd561f7df8eb6da50f8a8d81ba564342244d26d1d4211595");

        let hash_ptr = write_data(&mut fe_mut, &hash);
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let result =
            do_secp256k1_recover_pubkey(fe_mut.as_mut(), hash_ptr, sig_ptr, recovery_param)
                .unwrap();
        let error = result >> 32;
        let pubkey_ptr: u32 = (result & 0xFFFFFFFF).try_into().unwrap();
        assert_eq!(error, 0);
        assert_eq!(force_read(&mut fe_mut, pubkey_ptr), expected);
    }

    #[test]
    fn do_secp256r1_verify_works() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let hash = hex::decode(ECDSA_P256R1_HASH_HEX).unwrap();
        let hash_ptr = write_data(&mut fe_mut, &hash);
        let sig = hex::decode(ECDSA_P256R1_SIG_HEX).unwrap();
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let pubkey = hex::decode(ECDSA_P256R1_PUBKEY_HEX).unwrap();
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        assert_eq!(
            do_secp256r1_verify(fe_mut, hash_ptr, sig_ptr, pubkey_ptr).unwrap(),
            0
        );
    }

    #[test]
    fn do_secp256r1_verify_wrong_hash_verify_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let mut hash = hex::decode(ECDSA_P256R1_HASH_HEX).unwrap();
        // alter hash
        hash[0] ^= 0x01;
        let hash_ptr = write_data(&mut fe_mut, &hash);
        let sig = hex::decode(ECDSA_P256R1_SIG_HEX).unwrap();
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let pubkey = hex::decode(ECDSA_P256R1_PUBKEY_HEX).unwrap();
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        assert_eq!(
            do_secp256r1_verify(fe_mut, hash_ptr, sig_ptr, pubkey_ptr).unwrap(),
            1
        );
    }

    #[test]
    fn do_secp256r1_verify_larger_hash_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let mut hash = hex::decode(ECDSA_P256R1_HASH_HEX).unwrap();
        // extend / break hash
        hash.push(0x00);
        let hash_ptr = write_data(&mut fe_mut, &hash);
        let sig = hex::decode(ECDSA_P256R1_SIG_HEX).unwrap();
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let pubkey = hex::decode(ECDSA_P256R1_PUBKEY_HEX).unwrap();
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        let result = do_secp256r1_verify(fe_mut, hash_ptr, sig_ptr, pubkey_ptr);
        match result.unwrap_err() {
            VmError::CommunicationErr {
                source: CommunicationError::RegionLengthTooBig { length, .. },
                ..
            } => assert_eq!(length, MESSAGE_HASH_MAX_LEN + 1),
            e => panic!("Unexpected error: {e:?}"),
        }
    }

    #[test]
    fn do_secp256r1_verify_shorter_hash_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let mut hash = hex::decode(ECDSA_P256R1_HASH_HEX).unwrap();
        // reduce / break hash
        hash.pop();
        let hash_ptr = write_data(&mut fe_mut, &hash);
        let sig = hex::decode(ECDSA_P256R1_SIG_HEX).unwrap();
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let pubkey = hex::decode(ECDSA_P256R1_PUBKEY_HEX).unwrap();
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        assert_eq!(
            do_secp256r1_verify(fe_mut, hash_ptr, sig_ptr, pubkey_ptr).unwrap(),
            3 // mapped InvalidHashFormat
        );
    }

    #[test]
    fn do_secp256r1_verify_wrong_sig_verify_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let hash = hex::decode(ECDSA_P256R1_HASH_HEX).unwrap();
        let hash_ptr = write_data(&mut fe_mut, &hash);
        let mut sig = hex::decode(ECDSA_P256R1_SIG_HEX).unwrap();
        // alter sig
        sig[0] ^= 0x01;
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let pubkey = hex::decode(ECDSA_P256R1_PUBKEY_HEX).unwrap();
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        assert_eq!(
            do_secp256r1_verify(fe_mut, hash_ptr, sig_ptr, pubkey_ptr).unwrap(),
            1
        );
    }

    #[test]
    fn do_secp256r1_verify_larger_sig_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let hash = hex::decode(ECDSA_P256R1_HASH_HEX).unwrap();
        let hash_ptr = write_data(&mut fe_mut, &hash);
        let mut sig = hex::decode(ECDSA_P256R1_SIG_HEX).unwrap();
        // extend / break sig
        sig.push(0x00);
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let pubkey = hex::decode(ECDSA_P256R1_PUBKEY_HEX).unwrap();
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        let result = do_secp256r1_verify(fe_mut, hash_ptr, sig_ptr, pubkey_ptr);
        match result.unwrap_err() {
            VmError::CommunicationErr {
                source: CommunicationError::RegionLengthTooBig { length, .. },
                ..
            } => assert_eq!(length, ECDSA_SIGNATURE_LEN + 1),
            e => panic!("Unexpected error: {e:?}"),
        }
    }

    #[test]
    fn do_secp256r1_verify_shorter_sig_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let hash = hex::decode(ECDSA_P256R1_HASH_HEX).unwrap();
        let hash_ptr = write_data(&mut fe_mut, &hash);
        let mut sig = hex::decode(ECDSA_P256R1_SIG_HEX).unwrap();
        // reduce / break sig
        sig.pop();
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let pubkey = hex::decode(ECDSA_P256R1_PUBKEY_HEX).unwrap();
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        assert_eq!(
            do_secp256r1_verify(fe_mut, hash_ptr, sig_ptr, pubkey_ptr).unwrap(),
            4 // mapped InvalidSignatureFormat
        )
    }

    #[test]
    fn do_secp256r1_verify_wrong_pubkey_format_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let hash = hex::decode(ECDSA_P256R1_HASH_HEX).unwrap();
        let hash_ptr = write_data(&mut fe_mut, &hash);
        let sig = hex::decode(ECDSA_P256R1_SIG_HEX).unwrap();
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let mut pubkey = hex::decode(ECDSA_P256R1_PUBKEY_HEX).unwrap();
        // alter pubkey format
        pubkey[0] ^= 0x01;
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        assert_eq!(
            do_secp256r1_verify(fe_mut, hash_ptr, sig_ptr, pubkey_ptr).unwrap(),
            5 // mapped InvalidPubkeyFormat
        )
    }

    #[test]
    fn do_secp256r1_verify_wrong_pubkey_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let hash = hex::decode(ECDSA_P256R1_HASH_HEX).unwrap();
        let hash_ptr = write_data(&mut fe_mut, &hash);
        let sig = hex::decode(ECDSA_P256R1_SIG_HEX).unwrap();
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let mut pubkey = hex::decode(ECDSA_P256R1_PUBKEY_HEX).unwrap();
        // alter pubkey
        pubkey[1] ^= 0x01;
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        assert_eq!(
            do_secp256r1_verify(fe_mut, hash_ptr, sig_ptr, pubkey_ptr).unwrap(),
            10 // mapped GenericErr
        )
    }

    #[test]
    fn do_secp256r1_verify_larger_pubkey_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let hash = hex::decode(ECDSA_P256R1_HASH_HEX).unwrap();
        let hash_ptr = write_data(&mut fe_mut, &hash);
        let sig = hex::decode(ECDSA_P256R1_SIG_HEX).unwrap();
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let mut pubkey = hex::decode(ECDSA_P256R1_PUBKEY_HEX).unwrap();
        // extend / break pubkey
        pubkey.push(0x00);
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        let result = do_secp256r1_verify(fe_mut, hash_ptr, sig_ptr, pubkey_ptr);
        match result.unwrap_err() {
            VmError::CommunicationErr {
                source: CommunicationError::RegionLengthTooBig { length, .. },
                ..
            } => assert_eq!(length, ECDSA_PUBKEY_MAX_LEN + 1),
            e => panic!("Unexpected error: {e:?}"),
        }
    }

    #[test]
    fn do_secp256r1_verify_shorter_pubkey_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let hash = hex::decode(ECDSA_P256R1_HASH_HEX).unwrap();
        let hash_ptr = write_data(&mut fe_mut, &hash);
        let sig = hex::decode(ECDSA_P256R1_SIG_HEX).unwrap();
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let mut pubkey = hex::decode(ECDSA_P256R1_PUBKEY_HEX).unwrap();
        // reduce / break pubkey
        pubkey.pop();
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        assert_eq!(
            do_secp256r1_verify(fe_mut, hash_ptr, sig_ptr, pubkey_ptr).unwrap(),
            5 // mapped InvalidPubkeyFormat
        )
    }

    #[test]
    fn do_secp256r1_verify_empty_pubkey_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let hash = hex::decode(ECDSA_P256R1_HASH_HEX).unwrap();
        let hash_ptr = write_data(&mut fe_mut, &hash);
        let sig = hex::decode(ECDSA_P256R1_SIG_HEX).unwrap();
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let pubkey = vec![];
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        assert_eq!(
            do_secp256r1_verify(fe_mut, hash_ptr, sig_ptr, pubkey_ptr).unwrap(),
            5 // mapped InvalidPubkeyFormat
        )
    }

    #[test]
    fn do_secp256r1_verify_wrong_data_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let hash = vec![0x22; MESSAGE_HASH_MAX_LEN];
        let hash_ptr = write_data(&mut fe_mut, &hash);
        let sig = vec![0x22; ECDSA_SIGNATURE_LEN];
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let pubkey = vec![0x04; ECDSA_PUBKEY_MAX_LEN];
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        assert_eq!(
            do_secp256r1_verify(fe_mut, hash_ptr, sig_ptr, pubkey_ptr).unwrap(),
            10 // mapped GenericErr
        )
    }

    #[test]
    fn do_secp256r1_recover_pubkey_works() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let hash = hex!("12135386c09e0bf6fd5c454a95bcfe9b3edb25c71e455c73a212405694b29002");
        let sig = hex!("b53ce4da1aa7c0dc77a1896ab716b921499aed78df725b1504aba1597ba0c64bd7c246dc7ad0e67700c373edcfdd1c0a0495fc954549ad579df6ed1438840851");
        let recovery_param = 0;
        let expected = hex!("040a7dbb8bf50cb605eb2268b081f26d6b08e012f952c4b70a5a1e6e7d46af98bbf26dd7d799930062480849962ccf5004edcfd307c044f4e8f667c9baa834eeae");

        let hash_ptr = write_data(&mut fe_mut, &hash);
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let result =
            do_secp256r1_recover_pubkey(fe_mut.as_mut(), hash_ptr, sig_ptr, recovery_param)
                .unwrap();
        let error = result >> 32;
        let pubkey_ptr: u32 = (result & 0xFFFFFFFF).try_into().unwrap();
        assert_eq!(error, 0);
        assert_eq!(force_read(&mut fe_mut, pubkey_ptr), expected);
    }

    #[test]
    fn do_ed25519_verify_works() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let msg = hex::decode(EDDSA_MSG_HEX).unwrap();
        let msg_ptr = write_data(&mut fe_mut, &msg);
        let sig = hex::decode(EDDSA_SIG_HEX).unwrap();
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let pubkey = hex::decode(EDDSA_PUBKEY_HEX).unwrap();
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        assert_eq!(
            do_ed25519_verify(fe_mut, msg_ptr, sig_ptr, pubkey_ptr).unwrap(),
            0
        );
    }

    #[test]
    fn do_ed25519_verify_wrong_msg_verify_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let mut msg = hex::decode(EDDSA_MSG_HEX).unwrap();
        // alter msg
        msg.push(0x01);
        let msg_ptr = write_data(&mut fe_mut, &msg);
        let sig = hex::decode(EDDSA_SIG_HEX).unwrap();
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let pubkey = hex::decode(EDDSA_PUBKEY_HEX).unwrap();
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        assert_eq!(
            do_ed25519_verify(fe_mut, msg_ptr, sig_ptr, pubkey_ptr).unwrap(),
            1
        );
    }

    #[test]
    fn do_ed25519_verify_larger_msg_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let mut msg = hex::decode(EDDSA_MSG_HEX).unwrap();
        // extend / break msg
        msg.extend_from_slice(&[0x00; MAX_LENGTH_ED25519_MESSAGE + 1]);
        let msg_ptr = write_data(&mut fe_mut, &msg);
        let sig = hex::decode(EDDSA_SIG_HEX).unwrap();
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let pubkey = hex::decode(EDDSA_PUBKEY_HEX).unwrap();
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        let result = do_ed25519_verify(fe_mut, msg_ptr, sig_ptr, pubkey_ptr);
        match result.unwrap_err() {
            VmError::CommunicationErr {
                source: CommunicationError::RegionLengthTooBig { length, .. },
                ..
            } => assert_eq!(length, msg.len()),
            e => panic!("Unexpected error: {e:?}"),
        }
    }

    #[test]
    fn do_ed25519_verify_wrong_sig_verify_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let msg = hex::decode(EDDSA_MSG_HEX).unwrap();
        let msg_ptr = write_data(&mut fe_mut, &msg);
        let mut sig = hex::decode(EDDSA_SIG_HEX).unwrap();
        // alter sig
        sig[0] ^= 0x01;
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let pubkey = hex::decode(EDDSA_PUBKEY_HEX).unwrap();
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        assert_eq!(
            do_ed25519_verify(fe_mut, msg_ptr, sig_ptr, pubkey_ptr).unwrap(),
            1
        );
    }

    #[test]
    fn do_ed25519_verify_larger_sig_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let msg = hex::decode(EDDSA_MSG_HEX).unwrap();
        let msg_ptr = write_data(&mut fe_mut, &msg);
        let mut sig = hex::decode(EDDSA_SIG_HEX).unwrap();
        // extend / break sig
        sig.push(0x00);
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let pubkey = hex::decode(EDDSA_PUBKEY_HEX).unwrap();
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        let result = do_ed25519_verify(fe_mut, msg_ptr, sig_ptr, pubkey_ptr);
        match result.unwrap_err() {
            VmError::CommunicationErr {
                source: CommunicationError::RegionLengthTooBig { length, .. },
                ..
            } => assert_eq!(length, MAX_LENGTH_ED25519_SIGNATURE + 1),
            e => panic!("Unexpected error: {e:?}"),
        }
    }

    #[test]
    fn do_ed25519_verify_shorter_sig_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let msg = hex::decode(EDDSA_MSG_HEX).unwrap();
        let msg_ptr = write_data(&mut fe_mut, &msg);
        let mut sig = hex::decode(EDDSA_SIG_HEX).unwrap();
        // reduce / break sig
        sig.pop();
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let pubkey = hex::decode(EDDSA_PUBKEY_HEX).unwrap();
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        assert_eq!(
            do_ed25519_verify(fe_mut, msg_ptr, sig_ptr, pubkey_ptr).unwrap(),
            4 // mapped InvalidSignatureFormat
        )
    }

    #[test]
    fn do_ed25519_verify_wrong_pubkey_verify_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let msg = hex::decode(EDDSA_MSG_HEX).unwrap();
        let msg_ptr = write_data(&mut fe_mut, &msg);
        let sig = hex::decode(EDDSA_SIG_HEX).unwrap();
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let mut pubkey = hex::decode(EDDSA_PUBKEY_HEX).unwrap();
        // alter pubkey
        pubkey[1] ^= 0x01;
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        assert_eq!(
            do_ed25519_verify(fe_mut, msg_ptr, sig_ptr, pubkey_ptr).unwrap(),
            1
        );
    }

    #[test]
    fn do_ed25519_verify_larger_pubkey_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let msg = hex::decode(EDDSA_MSG_HEX).unwrap();
        let msg_ptr = write_data(&mut fe_mut, &msg);
        let sig = hex::decode(EDDSA_SIG_HEX).unwrap();
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let mut pubkey = hex::decode(EDDSA_PUBKEY_HEX).unwrap();
        // extend / break pubkey
        pubkey.push(0x00);
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        let result = do_ed25519_verify(fe_mut, msg_ptr, sig_ptr, pubkey_ptr);
        match result.unwrap_err() {
            VmError::CommunicationErr {
                source: CommunicationError::RegionLengthTooBig { length, .. },
                ..
            } => assert_eq!(length, EDDSA_PUBKEY_LEN + 1),
            e => panic!("Unexpected error: {e:?}"),
        }
    }

    #[test]
    fn do_ed25519_verify_shorter_pubkey_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let msg = hex::decode(EDDSA_MSG_HEX).unwrap();
        let msg_ptr = write_data(&mut fe_mut, &msg);
        let sig = hex::decode(EDDSA_SIG_HEX).unwrap();
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let mut pubkey = hex::decode(EDDSA_PUBKEY_HEX).unwrap();
        // reduce / break pubkey
        pubkey.pop();
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        assert_eq!(
            do_ed25519_verify(fe_mut, msg_ptr, sig_ptr, pubkey_ptr).unwrap(),
            5 // mapped InvalidPubkeyFormat
        )
    }

    #[test]
    fn do_ed25519_verify_empty_pubkey_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let msg = hex::decode(EDDSA_MSG_HEX).unwrap();
        let msg_ptr = write_data(&mut fe_mut, &msg);
        let sig = hex::decode(EDDSA_SIG_HEX).unwrap();
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let pubkey = vec![];
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        assert_eq!(
            do_ed25519_verify(fe_mut, msg_ptr, sig_ptr, pubkey_ptr).unwrap(),
            5 // mapped InvalidPubkeyFormat
        )
    }

    #[test]
    fn do_ed25519_verify_wrong_data_fails() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let msg = vec![0x22; MESSAGE_HASH_MAX_LEN];
        let msg_ptr = write_data(&mut fe_mut, &msg);
        let sig = vec![0x22; MAX_LENGTH_ED25519_SIGNATURE];
        let sig_ptr = write_data(&mut fe_mut, &sig);
        let pubkey = vec![0x04; EDDSA_PUBKEY_LEN];
        let pubkey_ptr = write_data(&mut fe_mut, &pubkey);

        assert_eq!(
            do_ed25519_verify(fe_mut, msg_ptr, sig_ptr, pubkey_ptr).unwrap(),
            1 // verification failure
        )
    }

    // ── Wave-1 multi-curve host DIFF (feature-gated; default feature-off stays green) ──

    /// Empty input → 32-byte BLAKE2b-256 written, host code 0.
    #[test]
    #[cfg(feature = "hash-blake")]
    fn do_blake2b_256_empty_writes_digest() {
        let api = MockApi::default();
        let (fe, mut store, instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let input_ptr = write_data(&mut fe_mut, &[]);
        let out_ptr = create_empty(&instance, &mut fe_mut, 32);

        assert_eq!(
            do_blake2b_256(fe_mut.as_mut(), input_ptr, out_ptr).unwrap(),
            0
        );
        let digest = force_read(&mut fe_mut, out_ptr);
        assert_eq!(digest.len(), 32);
        // RFC / standard BLAKE2b-256("") known vector.
        assert_eq!(
            digest,
            hex::decode("0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8")
                .unwrap()
        );
    }

    /// Poseidon-Pallas happy path: two small field elements → code 0 + 32-byte digest.
    #[test]
    #[cfg(feature = "hash-poseidon")]
    fn do_poseidon_hash_pallas_two_small_elements() {
        let api = MockApi::default();
        let (fe, mut store, instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        // Two LE Pasta field elements from small values 1 and 2.
        let mut input = vec![0u8; 64];
        input[0] = 1;
        input[32] = 2;
        let expected = cosmwasm_crypto::poseidon_hash_pallas_bytes(&input).unwrap();

        let inputs_ptr = write_data(&mut fe_mut, &input);
        let out_ptr = create_empty(&instance, &mut fe_mut, 32);

        assert_eq!(
            do_poseidon_hash_pallas(fe_mut.as_mut(), inputs_ptr, out_ptr).unwrap(),
            0
        );
        assert_eq!(force_read(&mut fe_mut, out_ptr), expected.as_slice());
    }

    /// Invalid field encoding (non-canonical) → soft-fail host code 1 (not VmError).
    #[test]
    #[cfg(feature = "hash-poseidon")]
    fn do_poseidon_hash_pallas_invalid_encoding_returns_1() {
        let api = MockApi::default();
        let (fe, mut store, instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let bad = [0xffu8; 32];
        let inputs_ptr = write_data(&mut fe_mut, &bad);
        let out_ptr = create_empty(&instance, &mut fe_mut, 32);

        assert_eq!(
            do_poseidon_hash_pallas(fe_mut.as_mut(), inputs_ptr, out_ptr).unwrap(),
            1
        );
    }

    /// Penumbra poseidon377 (BLS12-377 `decaf377::Fq`, not BLS12-381) rates 1..=6.
    /// Domain = LE Fq of `b"Penumbra_TestVec"`; inputs/outputs from the official testvec chain.
    #[test]
    #[cfg(feature = "hash-poseidon")]
    fn do_poseidon377_hash_penumbra_testvecs_rate_1_through_6() {
        use core::str::FromStr;
        use poseidon377::Fq;

        const CHAIN: &[&str] = &[
            "7553885614632219548127688026174585776320152166623257619763178041781456016062",
            "2337838243217876174544784248400816541933405738836087430664765452605435675740",
            "4318449279293553393006719276941638490334729643330833590842693275258805886300",
            "2884734248868891876687246055367204388444877057000108043377667455104051576315",
            "5235431038142849831913898188189800916077016298531443239266169457588889298166",
            "66948599770858083122195578203282720327054804952637730715402418442993895152",
            "6797655301930638258044003960605211404784492298673033525596396177265014216269",
        ];

        let api = MockApi::default();
        let (fe, mut store, instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let domain = Fq::from_le_bytes_mod_order(b"Penumbra_TestVec").to_bytes();
        let domain_ptr = write_data(&mut fe_mut, &domain);

        for rate in 1..=6 {
            let mut msg = Vec::new();
            for s in &CHAIN[..rate] {
                msg.extend_from_slice(&Fq::from_str(s).unwrap().to_bytes());
            }
            let expected = Fq::from_str(CHAIN[rate]).unwrap().to_bytes();
            let inputs_ptr = write_data(&mut fe_mut, &msg);
            let out_ptr = create_empty(&instance, &mut fe_mut, 32);
            assert_eq!(
                do_poseidon377_hash(fe_mut.as_mut(), domain_ptr, inputs_ptr, out_ptr).unwrap(),
                0,
                "host poseidon377 rate {rate} must succeed"
            );
            assert_eq!(
                force_read(&mut fe_mut, out_ptr),
                expected.as_slice(),
                "host poseidon377 rate {rate} must match Penumbra testvec"
            );
        }
    }

    #[test]
    #[cfg(feature = "hash-poseidon")]
    fn do_poseidon377_hash_bad_arity_returns_1() {
        let api = MockApi::default();
        let (fe, mut store, instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);
        let domain_ptr = write_data(&mut fe_mut, &[0u8; 32]);
        // Host caps message at 7*32; empty payload is a soft-fail (code 1), not RegionLengthTooBig.
        let inputs_ptr = write_data(&mut fe_mut, &[]);
        let out_ptr = create_empty(&instance, &mut fe_mut, 32);
        assert_eq!(
            do_poseidon377_hash(fe_mut.as_mut(), domain_ptr, inputs_ptr, out_ptr).unwrap(),
            1
        );
    }

    /// RedPallas SpendAuth: reddsa sign → host verify returns 0.
    #[test]
    #[cfg(feature = "redpallas")]
    fn do_redpallas_spendauth_verify_valid() {
        use rand_core::OsRng;
        use reddsa::{orchard as reddsa_orchard, SigningKey, VerificationKey};

        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let mut rng = OsRng;
        let sk = SigningKey::<reddsa_orchard::SpendAuth>::new(&mut rng);
        let vk = VerificationKey::from(&sk);
        let msg = b"terp-host-redpallas-roundtrip";
        let sig = sk.sign(&mut rng, msg);
        let vk_bytes: [u8; 32] = vk.into();
        let sig_bytes: [u8; 64] = sig.into();

        let msg_ptr = write_data(&mut fe_mut, msg);
        let sig_ptr = write_data(&mut fe_mut, &sig_bytes);
        let pk_ptr = write_data(&mut fe_mut, &vk_bytes);

        assert_eq!(
            do_redpallas_spendauth_verify(fe_mut.as_mut(), msg_ptr, sig_ptr, pk_ptr).unwrap(),
            0
        );
    }

    /// RedPallas SpendAuth: wrong message → host code 1 (invalid).
    #[test]
    #[cfg(feature = "redpallas")]
    fn do_redpallas_spendauth_verify_invalid() {
        use rand_core::OsRng;
        use reddsa::{orchard as reddsa_orchard, SigningKey, VerificationKey};

        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let mut rng = OsRng;
        let sk = SigningKey::<reddsa_orchard::SpendAuth>::new(&mut rng);
        let vk = VerificationKey::from(&sk);
        let msg = b"terp-host-redpallas-roundtrip";
        let sig = sk.sign(&mut rng, msg);
        let vk_bytes: [u8; 32] = vk.into();
        let sig_bytes: [u8; 64] = sig.into();

        let msg_ptr = write_data(&mut fe_mut, b"other-message");
        let sig_ptr = write_data(&mut fe_mut, &sig_bytes);
        let pk_ptr = write_data(&mut fe_mut, &vk_bytes);

        assert_eq!(
            do_redpallas_spendauth_verify(fe_mut.as_mut(), msg_ptr, sig_ptr, pk_ptr).unwrap(),
            1
        );
    }

    #[test]
    #[allow(deprecated)]
    fn do_query_chain_works() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let request: QueryRequest<Empty> = QueryRequest::Bank(BankQuery::Balance {
            address: INIT_ADDR.to_string(),
            denom: INIT_DENOM.to_string(),
        });
        let request_data = cosmwasm_std::to_json_vec(&request).unwrap();
        let request_ptr = write_data(&mut fe_mut, &request_data);

        leave_default_data(&mut fe_mut);

        let response_ptr = do_query_chain(fe_mut.as_mut(), request_ptr).unwrap();
        let response = force_read(&mut fe_mut, response_ptr);

        let query_result: cosmwasm_std::QuerierResult = from_json(response).unwrap();
        let query_result_inner = query_result.unwrap();
        let query_result_inner_inner = query_result_inner.unwrap();
        let parsed_again: BalanceResponse = from_json(query_result_inner_inner).unwrap();
        assert_eq!(parsed_again.amount, coin(INIT_AMOUNT, INIT_DENOM));
    }

    #[test]
    fn do_query_chain_fails_for_broken_request() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let request = b"Not valid JSON for sure";
        let request_ptr = write_data(&mut fe_mut, request);

        leave_default_data(&mut fe_mut);

        let response_ptr = do_query_chain(fe_mut.as_mut(), request_ptr).unwrap();
        let response = force_read(&mut fe_mut, response_ptr);

        let query_result: cosmwasm_std::QuerierResult = from_json(response).unwrap();
        match query_result {
            SystemResult::Ok(_) => panic!("This must not succeed"),
            SystemResult::Err(SystemError::InvalidRequest { request: err, .. }) => {
                assert_eq!(err.as_slice(), request)
            }
            SystemResult::Err(err) => panic!("Unexpected error: {err:?}"),
        }
    }

    #[test]
    fn do_query_chain_fails_for_missing_contract() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let request: QueryRequest<Empty> = QueryRequest::Wasm(WasmQuery::Smart {
            contract_addr: String::from("non-existent"),
            msg: Binary::from(b"{}" as &[u8]),
        });
        let request_data = cosmwasm_std::to_json_vec(&request).unwrap();
        let request_ptr = write_data(&mut fe_mut, &request_data);

        leave_default_data(&mut fe_mut);

        let response_ptr = do_query_chain(fe_mut.as_mut(), request_ptr).unwrap();
        let response = force_read(&mut fe_mut, response_ptr);

        let query_result: cosmwasm_std::QuerierResult = from_json(response).unwrap();
        match query_result {
            SystemResult::Ok(_) => panic!("This must not succeed"),
            SystemResult::Err(SystemError::NoSuchContract { addr }) => {
                assert_eq!(addr, "non-existent")
            }
            SystemResult::Err(err) => panic!("Unexpected error: {err:?}"),
        }
    }

    #[test]
    #[cfg(feature = "iterator")]
    fn do_db_scan_unbound_works() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);
        leave_default_data(&mut fe_mut);

        // set up iterator over all space
        let id = do_db_scan(fe_mut.as_mut(), 0, 0, Order::Ascending.into()).unwrap();
        assert_eq!(1, id);

        let item = fe_mut
            .data()
            .with_storage_from_context::<_, _>(|store| Ok(store.next(id)))
            .unwrap();
        assert_eq!(item.0.unwrap().unwrap(), (KEY1.to_vec(), VALUE1.to_vec()));

        let item = fe_mut
            .data()
            .with_storage_from_context::<_, _>(|store| Ok(store.next(id)))
            .unwrap();
        assert_eq!(item.0.unwrap().unwrap(), (KEY2.to_vec(), VALUE2.to_vec()));

        let item = fe_mut
            .data()
            .with_storage_from_context::<_, _>(|store| Ok(store.next(id)))
            .unwrap();
        assert!(item.0.unwrap().is_none());
    }

    #[test]
    #[cfg(feature = "iterator")]
    fn do_db_scan_unbound_descending_works() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);
        leave_default_data(&mut fe_mut);

        // set up iterator over all space
        let id = do_db_scan(fe_mut.as_mut(), 0, 0, Order::Descending.into()).unwrap();
        assert_eq!(1, id);

        let item = fe_mut
            .data()
            .with_storage_from_context::<_, _>(|store| Ok(store.next(id)))
            .unwrap();
        assert_eq!(item.0.unwrap().unwrap(), (KEY2.to_vec(), VALUE2.to_vec()));

        let item = fe_mut
            .data()
            .with_storage_from_context::<_, _>(|store| Ok(store.next(id)))
            .unwrap();
        assert_eq!(item.0.unwrap().unwrap(), (KEY1.to_vec(), VALUE1.to_vec()));

        let item = fe_mut
            .data()
            .with_storage_from_context::<_, _>(|store| Ok(store.next(id)))
            .unwrap();
        assert!(item.0.unwrap().is_none());
    }

    #[test]
    #[cfg(feature = "iterator")]
    fn do_db_scan_bound_works() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        let start = write_data(&mut fe_mut, b"anna");
        let end = write_data(&mut fe_mut, b"bert");

        leave_default_data(&mut fe_mut);

        let id = do_db_scan(fe_mut.as_mut(), start, end, Order::Ascending.into()).unwrap();

        let item = fe_mut
            .data()
            .with_storage_from_context::<_, _>(|store| Ok(store.next(id)))
            .unwrap();
        assert_eq!(item.0.unwrap().unwrap(), (KEY1.to_vec(), VALUE1.to_vec()));

        let item = fe_mut
            .data()
            .with_storage_from_context::<_, _>(|store| Ok(store.next(id)))
            .unwrap();
        assert!(item.0.unwrap().is_none());
    }

    #[test]
    #[cfg(feature = "iterator")]
    fn do_db_scan_multiple_iterators() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);
        leave_default_data(&mut fe_mut);

        // unbounded, ascending and descending
        let id1 = do_db_scan(fe_mut.as_mut(), 0, 0, Order::Ascending.into()).unwrap();
        let id2 = do_db_scan(fe_mut.as_mut(), 0, 0, Order::Descending.into()).unwrap();
        assert_eq!(id1, 1);
        assert_eq!(id2, 2);

        // first item, first iterator
        let item = fe_mut
            .data()
            .with_storage_from_context::<_, _>(|store| Ok(store.next(id1)))
            .unwrap();
        assert_eq!(item.0.unwrap().unwrap(), (KEY1.to_vec(), VALUE1.to_vec()));

        // second item, first iterator
        let item = fe_mut
            .data()
            .with_storage_from_context::<_, _>(|store| Ok(store.next(id1)))
            .unwrap();
        assert_eq!(item.0.unwrap().unwrap(), (KEY2.to_vec(), VALUE2.to_vec()));

        // first item, second iterator
        let item = fe_mut
            .data()
            .with_storage_from_context::<_, _>(|store| Ok(store.next(id2)))
            .unwrap();
        assert_eq!(item.0.unwrap().unwrap(), (KEY2.to_vec(), VALUE2.to_vec()));

        // end, first iterator
        let item = fe_mut
            .data()
            .with_storage_from_context::<_, _>(|store| Ok(store.next(id1)))
            .unwrap();
        assert!(item.0.unwrap().is_none());

        // second item, second iterator
        let item = fe_mut
            .data()
            .with_storage_from_context::<_, _>(|store| Ok(store.next(id2)))
            .unwrap();
        assert_eq!(item.0.unwrap().unwrap(), (KEY1.to_vec(), VALUE1.to_vec()));
    }

    #[test]
    #[cfg(feature = "iterator")]
    fn do_db_scan_errors_for_invalid_order_value() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);
        leave_default_data(&mut fe_mut);

        // set up iterator over all space
        let result = do_db_scan(fe_mut, 0, 0, 42);
        match result.unwrap_err() {
            VmError::CommunicationErr {
                source: CommunicationError::InvalidOrder { .. },
                ..
            } => {}
            e => panic!("Unexpected error: {e:?}"),
        }
    }

    #[test]
    #[cfg(feature = "iterator")]
    fn do_db_next_works() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        leave_default_data(&mut fe_mut);

        let id = do_db_scan(fe_mut.as_mut(), 0, 0, Order::Ascending.into()).unwrap();

        // Entry 1
        let kv_region_ptr = do_db_next(fe_mut.as_mut(), id).unwrap();
        assert_eq!(
            force_read(&mut fe_mut, kv_region_ptr),
            [KEY1, b"\0\0\0\x03", VALUE1, b"\0\0\0\x06"].concat()
        );

        // Entry 2
        let kv_region_ptr = do_db_next(fe_mut.as_mut(), id).unwrap();
        assert_eq!(
            force_read(&mut fe_mut, kv_region_ptr),
            [KEY2, b"\0\0\0\x04", VALUE2, b"\0\0\0\x05"].concat()
        );

        // End
        let kv_region_ptr = do_db_next(fe_mut.as_mut(), id).unwrap();
        assert_eq!(force_read(&mut fe_mut, kv_region_ptr), b"\0\0\0\0\0\0\0\0");
        // API makes no guarantees for value_ptr in this case
    }

    #[test]
    #[cfg(feature = "iterator")]
    fn do_db_next_fails_for_non_existent_id() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        leave_default_data(&mut fe_mut);

        let non_existent_id = 42u32;
        let result = do_db_next(fe_mut.as_mut(), non_existent_id);
        match result.unwrap_err() {
            VmError::BackendErr {
                source: BackendError::IteratorDoesNotExist { id, .. },
                ..
            } => assert_eq!(id, non_existent_id),
            e => panic!("Unexpected error: {e:?}"),
        }
    }

    #[test]
    #[cfg(feature = "iterator")]
    fn do_db_next_key_works() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        leave_default_data(&mut fe_mut);

        let id = do_db_scan(fe_mut.as_mut(), 0, 0, Order::Ascending.into()).unwrap();

        // Entry 1
        let key_region_ptr = do_db_next_key(fe_mut.as_mut(), id).unwrap();
        assert_eq!(force_read(&mut fe_mut, key_region_ptr), KEY1);

        // Entry 2
        let key_region_ptr = do_db_next_key(fe_mut.as_mut(), id).unwrap();
        assert_eq!(force_read(&mut fe_mut, key_region_ptr), KEY2);

        // End
        let key_region_ptr: u32 = do_db_next_key(fe_mut.as_mut(), id).unwrap();
        assert_eq!(key_region_ptr, 0);
    }

    #[test]
    #[cfg(feature = "iterator")]
    fn do_db_next_value_works() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        leave_default_data(&mut fe_mut);

        let id = do_db_scan(fe_mut.as_mut(), 0, 0, Order::Ascending.into()).unwrap();

        // Entry 1
        let value_region_ptr = do_db_next_value(fe_mut.as_mut(), id).unwrap();
        assert_eq!(force_read(&mut fe_mut, value_region_ptr), VALUE1);

        // Entry 2
        let value_region_ptr = do_db_next_value(fe_mut.as_mut(), id).unwrap();
        assert_eq!(force_read(&mut fe_mut, value_region_ptr), VALUE2);

        // End
        let value_region_ptr = do_db_next_value(fe_mut.as_mut(), id).unwrap();
        assert_eq!(value_region_ptr, 0);
    }

    #[test]
    #[cfg(feature = "iterator")]
    fn do_db_next_works_mixed() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);

        leave_default_data(&mut fe_mut);

        let id = do_db_scan(fe_mut.as_mut(), 0, 0, Order::Ascending.into()).unwrap();

        // Key 1
        let key_region_ptr = do_db_next_key(fe_mut.as_mut(), id).unwrap();
        assert_eq!(force_read(&mut fe_mut, key_region_ptr), KEY1);

        // Value 2
        let value_region_ptr = do_db_next_value(fe_mut.as_mut(), id).unwrap();
        assert_eq!(force_read(&mut fe_mut, value_region_ptr), VALUE2);

        // End
        let kv_region_ptr = do_db_next(fe_mut.as_mut(), id).unwrap();
        assert_eq!(force_read(&mut fe_mut, kv_region_ptr), b"\0\0\0\0\0\0\0\0");
    }

    // ── Path A BN254 Groth16 (feature bn254) ──────────────────────────────

    /// Path A cold-path e2e: zkid=42 → CircuitInfo → Circuit blob → verify.
    /// Proves instance routing uses footer.curve_id (4), not zkid.
    #[test]
    #[cfg(all(feature = "zk", feature = "bn254"))]
    fn proof_instance_verify_bn254_zkid_42_cold_path() {
        use cosmwasm_std::{
            to_json_binary, Addr, CircuitInfoResponse, CircuitResponse, ContractResult,
            SystemResult, WasmQuery,
        };

        static SQUARE_BLOB: &[u8] = include_bytes!("../../zk/testdata/square_vk.bin");
        static SQUARE_PROOF: &[u8] = include_bytes!("../../zk/testdata/square_proof.bin");
        static SQUARE_PUBLIC: &[u8] = include_bytes!("../../zk/testdata/square_public.bin");

        // H-06: CircuitInfo.circuit_key must match footer-derived identity of the blob.
        let circuit_key = crate::zk::check_circuit(SQUARE_BLOB)
            .expect("square fixture footer")
            .to_circuit_key();

        let api = MockApi::default();
        // Schedule for square verify ~3.3e9; this test charges multiple verifies.
        let (fe, mut store, _instance) =
            make_instance_with_gas_limit(api, TESTING_ZK_VERIFY_GAS_LIMIT);
        let mut fe_mut = fe.into_mut(&mut store);

        // Storage + querier: CircuitInfo/Circuit for zkid=42 only.
        let mut storage = MockStorage::new();
        storage.set(KEY1, VALUE1).0.expect("set");
        let mut querier: MockQuerier<Empty> =
            MockQuerier::new(&[(INIT_ADDR, &coins(INIT_AMOUNT, INIT_DENOM))]);
        let blob = SQUARE_BLOB.to_vec();
        let key_bin = circuit_key.to_vec();
        querier.update_wasm(move |wq| match wq {
            WasmQuery::CircuitInfo { zk_id } if *zk_id == 42 => {
                let response = CircuitInfoResponse::new(
                    42,
                    Addr::unchecked("creator"),
                    cosmwasm_std::Binary::from(key_bin.clone()),
                );
                SystemResult::Ok(ContractResult::Ok(to_json_binary(&response).unwrap()))
            }
            WasmQuery::Circuit { zk_id } if *zk_id == 42 => {
                let response = CircuitResponse::new(cosmwasm_std::Binary::from(blob.clone()));
                SystemResult::Ok(ContractResult::Ok(to_json_binary(&response).unwrap()))
            }
            WasmQuery::CircuitInfo { zk_id } | WasmQuery::Circuit { zk_id } => {
                SystemResult::Err(SystemError::NoSuchCircuit { zk_id: *zk_id })
            }
            _ => SystemResult::Err(SystemError::UnsupportedRequest {
                kind: "query".into(),
            }),
        });
        {
            let (env, _store) = fe_mut.data_and_store_mut();
            env.move_in(storage, querier);
            // No circuit_loader → force cold path via WasmQuery::Circuit.
            env.set_circuit_loader(None);
        }

        let proof_ptr = write_data(&mut fe_mut, SQUARE_PROOF);
        let inst_ptr = write_data(&mut fe_mut, SQUARE_PUBLIC);

        // zkid=42 ≠ curve_id=4 — must still succeed (D7).
        let code = do_proof_instance_verify(
            fe_mut.as_mut(),
            42,
            proof_ptr,
            SQUARE_PROOF.len() as u32,
            inst_ptr,
            SQUARE_PUBLIC.len() as u32,
        )
        .expect("format ok");
        assert_eq!(code, 0, "valid golden must return 0");

        // Bit-flip proof → Ok(1) or format Err (both non-success for auth).
        let mut bad = SQUARE_PROOF.to_vec();
        if let Some(b) = bad.last_mut() {
            *b ^= 0xff;
        }
        let bad_ptr = write_data(&mut fe_mut, &bad);
        let bad_res = do_proof_instance_verify(
            fe_mut.as_mut(),
            42,
            bad_ptr,
            bad.len() as u32,
            inst_ptr,
            SQUARE_PUBLIC.len() as u32,
        );
        match bad_res {
            Ok(1) => {}  // crypto false
            Err(_) => {} // format error on corrupt proof
            Ok(0) => panic!("bit-flipped proof must not verify"),
            Ok(other) => panic!("unexpected code {other}"),
        }

        // Wrong PI length → host Err (format), not Ok(0).
        let wrong_pi = [0u8; 64]; // 2 limbs, circuit expects 1
        let wrong_ptr = write_data(&mut fe_mut, &wrong_pi);
        let len_res = do_proof_instance_verify(
            fe_mut.as_mut(),
            42,
            proof_ptr,
            SQUARE_PROOF.len() as u32,
            wrong_ptr,
            wrong_pi.len() as u32,
        );
        assert!(len_res.is_err(), "PI length mismatch must be host Err");
    }

    /// Path A with circuit_loader hit (cache) after store_circuit of golden.
    #[test]
    #[cfg(all(feature = "zk", feature = "bn254"))]
    fn proof_instance_verify_bn254_loader_hit() {
        use crate::cache::Cache;
        use crate::config::CacheOptions;
        use crate::size::Size;
        use cosmwasm_std::{
            to_json_binary, Addr, CircuitInfoResponse, ContractResult, SystemResult, WasmQuery,
        };
        use std::collections::HashSet;
        use tempfile::TempDir;

        static SQUARE_BLOB: &[u8] = include_bytes!("../../zk/testdata/square_vk.bin");
        static SQUARE_PROOF: &[u8] = include_bytes!("../../zk/testdata/square_proof.bin");
        static SQUARE_PUBLIC: &[u8] = include_bytes!("../../zk/testdata/square_public.bin");

        let temp = TempDir::new().unwrap();
        let opts = CacheOptions {
            base_dir: temp.path().into(),
            available_capabilities: HashSet::from(["cosmwasm_1_1".into(), "cosmwasm_2_0".into()]),
            memory_cache_size_bytes: Size::mebi(32),
            instance_memory_limit_bytes: Size::mebi(16),
        };
        let cache: Cache<MockApi, MockStorage, MockQuerier> = unsafe { Cache::new(opts).unwrap() };
        let circuit_key = cache.store_circuit(SQUARE_BLOB, true).unwrap();
        let loader = cache.circuit_loader();

        let api = MockApi::default();
        // Schedule for square verify ~3.3e9 >> default TESTING_GAS_LIMIT (~1e9).
        let (fe, mut store, _instance) =
            make_instance_with_gas_limit(api, TESTING_ZK_VERIFY_GAS_LIMIT);
        let mut fe_mut = fe.into_mut(&mut store);

        let mut storage = MockStorage::new();
        storage.set(KEY1, VALUE1).0.expect("set");
        let mut querier: MockQuerier<Empty> =
            MockQuerier::new(&[(INIT_ADDR, &coins(INIT_AMOUNT, INIT_DENOM))]);
        let key_bin = circuit_key.to_vec();
        querier.update_wasm(move |wq| match wq {
            WasmQuery::CircuitInfo { zk_id } if *zk_id == 42 => {
                let response = CircuitInfoResponse::new(
                    42,
                    Addr::unchecked("creator"),
                    cosmwasm_std::Binary::from(key_bin.clone()),
                );
                SystemResult::Ok(ContractResult::Ok(to_json_binary(&response).unwrap()))
            }
            WasmQuery::CircuitInfo { zk_id } | WasmQuery::Circuit { zk_id } => {
                SystemResult::Err(SystemError::NoSuchCircuit { zk_id: *zk_id })
            }
            _ => SystemResult::Err(SystemError::UnsupportedRequest {
                kind: "query".into(),
            }),
        });
        {
            let (env, _store) = fe_mut.data_and_store_mut();
            env.move_in(storage, querier);
            env.set_circuit_loader(Some(loader));
        }

        let proof_ptr = write_data(&mut fe_mut, SQUARE_PROOF);
        let inst_ptr = write_data(&mut fe_mut, SQUARE_PUBLIC);
        let code = do_proof_instance_verify(
            fe_mut.as_mut(),
            42,
            proof_ptr,
            SQUARE_PROOF.len() as u32,
            inst_ptr,
            SQUARE_PUBLIC.len() as u32,
        )
        .expect("loader path");
        assert_eq!(code, 0);
    }

    /// Missing CircuitInfo/Circuit for zkid → host Err (not process panic, not Ok(0)).
    #[test]
    #[cfg(feature = "zk")]
    fn proof_instance_verify_missing_circuit_is_err_not_panic() {
        use cosmwasm_std::{ContractResult, SystemResult, WasmQuery};

        let api = MockApi::default();
        let (fe, mut store, _instance) =
            make_instance_with_gas_limit(api, TESTING_ZK_VERIFY_GAS_LIMIT);
        let mut fe_mut = fe.into_mut(&mut store);

        let mut storage = MockStorage::new();
        storage.set(KEY1, VALUE1).0.expect("set");
        let mut querier: MockQuerier<Empty> =
            MockQuerier::new(&[(INIT_ADDR, &coins(INIT_AMOUNT, INIT_DENOM))]);
        querier.update_wasm(move |wq| match wq {
            WasmQuery::CircuitInfo { zk_id } | WasmQuery::Circuit { zk_id } => {
                SystemResult::Err(SystemError::NoSuchCircuit { zk_id: *zk_id })
            }
            _ => SystemResult::Err(SystemError::UnsupportedRequest {
                kind: "query".into(),
            }),
        });
        {
            let (env, _store) = fe_mut.data_and_store_mut();
            env.move_in(storage, querier);
            env.set_circuit_loader(None);
        }

        let proof = [0u8; 8];
        let inst = [0u8; 8];
        let proof_ptr = write_data(&mut fe_mut, &proof);
        let inst_ptr = write_data(&mut fe_mut, &inst);

        let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            do_proof_instance_verify(
                fe_mut.as_mut(),
                99,
                proof_ptr,
                proof.len() as u32,
                inst_ptr,
                inst.len() as u32,
            )
        }));
        let inner = res.expect("VM must not panic on missing circuit");
        assert!(
            inner.is_err(),
            "missing circuit must be host Err, not Ok(0)"
        );
    }

    /// Circle STWO through Path A. Without STWO_HOST_VERIFY, dummy DSTW is rejected.
    #[test]
    #[cfg(feature = "zk")]
    fn proof_instance_verify_stwo_ok_bad_proof_missing_not_panic() {
        use cosmwasm_std::{
            to_json_binary, Addr, CircuitInfoResponse, CircuitResponse, ContractResult,
            SystemResult, WasmQuery,
        };

        let vk = zk_cosmwasm::StwoVerifyingKey::lean_default();
        let blob = vk.to_blob();
        let circuit_key = vk.footer.to_circuit_key();

        // DSTW dummy: c = 3a+5b+7 over M31
        let a: u32 = 3;
        let b: u32 = 5;
        let c = ((3u64 * u64::from(a) + 5u64 * u64::from(b) + 7) % ((1u64 << 31) - 1)) as u32;
        let mut dstw = vec![0u8; 18];
        dstw[0..4].copy_from_slice(b"DSTW");
        dstw[4] = 2;
        dstw[5] = 5;
        dstw[6..10].copy_from_slice(&a.to_le_bytes());
        dstw[10..14].copy_from_slice(&b.to_le_bytes());
        dstw[14..18].copy_from_slice(&c.to_le_bytes());

        let api = MockApi::default();
        let (fe, mut store, _instance) =
            make_instance_with_gas_limit(api, TESTING_ZK_VERIFY_GAS_LIMIT);
        let mut fe_mut = fe.into_mut(&mut store);

        let mut storage = MockStorage::new();
        storage.set(KEY1, VALUE1).0.expect("set");
        let mut querier: MockQuerier<Empty> =
            MockQuerier::new(&[(INIT_ADDR, &coins(INIT_AMOUNT, INIT_DENOM))]);
        let blob_c = blob.clone();
        let key_bin = circuit_key.to_vec();
        querier.update_wasm(move |wq| match wq {
            WasmQuery::CircuitInfo { zk_id } if *zk_id == 7 => {
                let response = CircuitInfoResponse::new(
                    7,
                    Addr::unchecked("creator"),
                    cosmwasm_std::Binary::from(key_bin.clone()),
                );
                SystemResult::Ok(ContractResult::Ok(to_json_binary(&response).unwrap()))
            }
            WasmQuery::Circuit { zk_id } if *zk_id == 7 => {
                let response = CircuitResponse::new(cosmwasm_std::Binary::from(blob_c.clone()));
                SystemResult::Ok(ContractResult::Ok(to_json_binary(&response).unwrap()))
            }
            WasmQuery::CircuitInfo { zk_id } | WasmQuery::Circuit { zk_id } => {
                SystemResult::Err(SystemError::NoSuchCircuit { zk_id: *zk_id })
            }
            _ => SystemResult::Err(SystemError::UnsupportedRequest {
                kind: "query".into(),
            }),
        });
        {
            let (env, _store) = fe_mut.data_and_store_mut();
            env.move_in(storage, querier);
            env.set_circuit_loader(None);
        }

        let proof_ptr = write_data(&mut fe_mut, &dstw);
        let inst_ptr = write_data(&mut fe_mut, &[]);

        let ok = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            do_proof_instance_verify(
                fe_mut.as_mut(),
                7,
                proof_ptr,
                dstw.len() as u32,
                inst_ptr,
                0,
            )
        }))
        .expect("no panic on dummy DSTW");
        match ok {
            Ok(1) => {}
            Err(_) => {}
            Ok(0) => panic!("dummy DSTW must not Ok(0) without host verifier"),
            Ok(other) => panic!("unexpected code {other}"),
        }

        let mut bad = dstw.clone();
        bad[14] ^= 1;
        let bad_ptr = write_data(&mut fe_mut, &bad);
        let bad_res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            do_proof_instance_verify(fe_mut.as_mut(), 7, bad_ptr, bad.len() as u32, inst_ptr, 0)
        }))
        .expect("no panic on bad proof");
        match bad_res {
            Ok(1) => {}
            Err(_) => {}
            Ok(0) => panic!("bad STWO proof must not Ok(0)"),
            Ok(other) => panic!("unexpected code {other}"),
        }

        let miss = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            do_proof_instance_verify(
                fe_mut.as_mut(),
                99,
                proof_ptr,
                dstw.len() as u32,
                inst_ptr,
                0,
            )
        }))
        .expect("no panic on missing STWO circuit");
        assert!(miss.is_err(), "missing STWO zkid must be host Err");
    }

    // ── Path A batch verify (proof_instance_batch_verify) ─────────────────

    /// Empty batch: section-empty inputs → Ok(0), gas charged (base only).
    #[test]
    #[cfg(feature = "zk")]
    fn proof_instance_batch_verify_empty_ok() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);
        leave_default_data(&mut fe_mut);

        // Empty section payloads (decode_sections(&[]) → []).
        let zkids_ptr = write_data(&mut fe_mut, &[]);
        let proofs_ptr = write_data(&mut fe_mut, &[]);
        let instances_ptr = write_data(&mut fe_mut, &[]);

        let code =
            do_proof_instance_batch_verify(fe_mut.as_mut(), zkids_ptr, proofs_ptr, instances_ptr)
                .expect("empty batch");
        assert_eq!(code, 0, "empty batch is vacuously valid");
    }

    // Residual H-06 (R-LF): FS/loader key re-bind mismatch on batch cold/FS-hit paths
    // is still a SEAM ticket — not closed by empty/length-mismatch tests alone.
    // Prefer dedicated `proof_instance_batch_verify_bn254_h06_key_mismatch_err` when
    // a fixture + circuit_loader harness can pin a wrong key without rewriting batch gas.

    /// Length mismatch between section lists → host Err (before verify).
    #[test]
    #[cfg(feature = "zk")]
    fn proof_instance_batch_verify_length_mismatch_err() {
        let api = MockApi::default();
        let (fe, mut store, _instance) = make_instance(api);
        let mut fe_mut = fe.into_mut(&mut store);
        leave_default_data(&mut fe_mut);

        // One zkid section, zero proofs/instances.
        let zkid_enc = encode_sections(&[42u64.to_le_bytes().to_vec()]).unwrap();
        let zkids_ptr = write_data(&mut fe_mut, &zkid_enc);
        let proofs_ptr = write_data(&mut fe_mut, &[]);
        let instances_ptr = write_data(&mut fe_mut, &[]);

        let res =
            do_proof_instance_batch_verify(fe_mut.as_mut(), zkids_ptr, proofs_ptr, instances_ptr);
        assert!(res.is_err(), "mismatched section counts must error");
    }

    /// Small batch (n=2 identical goldens) via cold path → Ok(0).
    #[test]
    #[cfg(all(feature = "zk", feature = "bn254"))]
    fn proof_instance_batch_verify_bn254_small_batch() {
        use cosmwasm_std::{
            to_json_binary, Addr, CircuitInfoResponse, CircuitResponse, ContractResult,
            SystemResult, WasmQuery,
        };

        static SQUARE_BLOB: &[u8] = include_bytes!("../../zk/testdata/square_vk.bin");
        static SQUARE_PROOF: &[u8] = include_bytes!("../../zk/testdata/square_proof.bin");
        static SQUARE_PUBLIC: &[u8] = include_bytes!("../../zk/testdata/square_public.bin");

        let circuit_key = crate::zk::check_circuit(SQUARE_BLOB)
            .expect("square fixture footer")
            .to_circuit_key();

        let api = MockApi::default();
        let (fe, mut store, _instance) =
            make_instance_with_gas_limit(api, TESTING_ZK_VERIFY_GAS_LIMIT);
        let mut fe_mut = fe.into_mut(&mut store);

        let mut storage = MockStorage::new();
        storage.set(KEY1, VALUE1).0.expect("set");
        let mut querier: MockQuerier<Empty> =
            MockQuerier::new(&[(INIT_ADDR, &coins(INIT_AMOUNT, INIT_DENOM))]);
        let blob = SQUARE_BLOB.to_vec();
        let key_bin = circuit_key.to_vec();
        querier.update_wasm(move |wq| match wq {
            WasmQuery::CircuitInfo { zk_id } if *zk_id == 42 => {
                let response = CircuitInfoResponse::new(
                    42,
                    Addr::unchecked("creator"),
                    cosmwasm_std::Binary::from(key_bin.clone()),
                );
                SystemResult::Ok(ContractResult::Ok(to_json_binary(&response).unwrap()))
            }
            WasmQuery::Circuit { zk_id } if *zk_id == 42 => {
                let response = CircuitResponse::new(cosmwasm_std::Binary::from(blob.clone()));
                SystemResult::Ok(ContractResult::Ok(to_json_binary(&response).unwrap()))
            }
            WasmQuery::CircuitInfo { zk_id } | WasmQuery::Circuit { zk_id } => {
                SystemResult::Err(SystemError::NoSuchCircuit { zk_id: *zk_id })
            }
            _ => SystemResult::Err(SystemError::UnsupportedRequest {
                kind: "query".into(),
            }),
        });
        {
            let (env, _store) = fe_mut.data_and_store_mut();
            env.move_in(storage, querier);
            env.set_circuit_loader(None);
        }

        // Two identical items (same zkid / proof / PI).
        let zkid_a = 42u64.to_le_bytes().to_vec();
        let zkid_b = 42u64.to_le_bytes().to_vec();
        let zkids_enc = encode_sections(&[zkid_a, zkid_b]).unwrap();
        let proofs_enc = encode_sections(&[SQUARE_PROOF.to_vec(), SQUARE_PROOF.to_vec()]).unwrap();
        let inst_enc = encode_sections(&[SQUARE_PUBLIC.to_vec(), SQUARE_PUBLIC.to_vec()]).unwrap();

        let zkids_ptr = write_data(&mut fe_mut, &zkids_enc);
        let proofs_ptr = write_data(&mut fe_mut, &proofs_enc);
        let inst_ptr = write_data(&mut fe_mut, &inst_enc);

        let code = do_proof_instance_batch_verify(fe_mut.as_mut(), zkids_ptr, proofs_ptr, inst_ptr)
            .expect("batch format ok");
        assert_eq!(code, 0, "batch of two goldens must verify");

        // One valid + one bit-flipped → non-success.
        let mut bad = SQUARE_PROOF.to_vec();
        if let Some(b) = bad.last_mut() {
            *b ^= 0xff;
        }
        let zkids_enc2 =
            encode_sections(&[42u64.to_le_bytes().to_vec(), 42u64.to_le_bytes().to_vec()]).unwrap();
        let proofs_enc2 = encode_sections(&[SQUARE_PROOF.to_vec(), bad]).unwrap();
        let inst_enc2 = encode_sections(&[SQUARE_PUBLIC.to_vec(), SQUARE_PUBLIC.to_vec()]).unwrap();
        let zkids_ptr2 = write_data(&mut fe_mut, &zkids_enc2);
        let proofs_ptr2 = write_data(&mut fe_mut, &proofs_enc2);
        let inst_ptr2 = write_data(&mut fe_mut, &inst_enc2);
        let bad_res =
            do_proof_instance_batch_verify(fe_mut.as_mut(), zkids_ptr2, proofs_ptr2, inst_ptr2);
        match bad_res {
            Ok(1) => {}
            Err(_) => {}
            Ok(0) => panic!("batch with bit-flipped proof must not all-verify"),
            Ok(other) => panic!("unexpected code {other}"),
        }
    }
}
