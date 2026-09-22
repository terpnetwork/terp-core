//! Derive macros for cosmwasm-vm. For internal use only. No stability guarantees.
//!
//! CosmWasm is a smart contract platform for the Cosmos ecosystem.
//! For more information, see: <https://cosmwasm.cosmos.network>

mod code_generators;
mod cosmwasm_circuit;
mod hash_function;
mod parsers;
mod validators;

#[cfg(test)]
mod tests;

macro_rules! maybe {
    ($result:expr) => {{
        match { $result } {
            Ok(val) => val,
            Err(err) => return err.into_compile_error(),
        }
    }};
}
use maybe;

/// Hash the function
///
/// # Example
///
/// ```rust
/// # use cosmwasm_vm_derive::hash_function;
/// #[hash_function(const_name = "HASH")]
/// fn foo() {
///     println!("Hello, world!");
/// }
/// ```
#[proc_macro_attribute]
pub fn hash_function(
    attr: proc_macro::TokenStream,
    item: proc_macro::TokenStream,
) -> proc_macro::TokenStream {
    hash_function::hash_function_impl(attr.into(), item.into()).into()
}

/// Derive macro for CosmWasm-compatible Halo2 circuits (Version 2.0)
///
/// This macro enables ZK circuit developers to create circuits compatible with
/// the CosmWasm VM by automatically generating serialization logic, footer
/// metadata, and constraint system analysis.
///
/// # Required Attributes
///
/// - `k`: Circuit size parameter (2^k rows), must be in range [11, 20]
/// - `instances`: Number of public inputs, must be in range [1, 255]
///
/// # Optional Attributes
///
/// - `circuit_type`: Serialization format variant (default: "Plonkish")
/// - `footer_version`: Footer format version, 1 or 2 (default: 2)
/// - `analyze_cs`: Whether to perform CS analysis (default: true)
///
/// # Generated Methods
///
/// The macro generates the following methods on `CosmwasmCircuitFor<YourCircuit>`:
///
/// - `circuit_metadata()` - Basic circuit metadata
/// - `verifying_key()` - Build the verifying key
/// - `ct()` - Get the circuit type
/// - `instance_count()` - Get the public input count
/// - `k_parameter()` - Get the circuit size parameter
/// - `is_compatible(instances)` - Validate instance count
/// - `constraint_system_metadata()` - Get CS analysis results (when analyze_cs=true)
/// - `footer()` - Get the CircuitFooter for serialization
/// - `to_bytes_with_cs()` - Serialize with constraint system (version 2 format)
/// - `from_bytes_with_cs(bytes)` - Deserialize from bytes
/// - `serialize_for_vm()` - Serialize for WASM FFI transmission
///
/// # Generated Constants
///
/// - `YOURCIRCUIT_K: u32` - Circuit size parameter
/// - `YOURCIRCUIT_INSTANCES: u8` - Number of public inputs
/// - `YOURCIRCUIT_METADATA: PlonkishCircuitMetadata` - Compile-time metadata
///
/// # Example
///
/// ```ignore
/// use cosmwasm_vm_derive::cosmwasm_circuit;
/// use halo2_proofs::plonk::Circuit;
/// use pasta_curves::vesta;
///
/// #[cosmwasm_circuit(k = 17, instances = 2)]
/// #[derive(Default)]
/// pub struct MyCircuit {
///     secret: Option<vesta::Scalar>,
/// }
///
/// impl Circuit<vesta::Scalar> for MyCircuit {
///     // ... standard halo2 implementation ...
/// }
///
/// // Now automatically available:
/// let cs_meta = MyCircuit::constraint_system_metadata();
/// let footer = MyCircuit::footer();
/// let serialized = MyCircuit::to_bytes_with_cs()?;
/// let vm_data = MyCircuit::serialize_for_vm()?;
/// ```
///
/// # Legacy Mode
///
/// For backward compatibility, you can use `analyze_cs = false` and
/// `footer_version = 1` to generate version 1 format without CS analysis:
///
/// ```ignore
/// #[cosmwasm_circuit(k = 17, instances = 2, footer_version = 1, analyze_cs = false)]
/// pub struct LegacyCircuit { ... }
/// ```
///
/// # Version 2 Format
///
/// The version 2 format includes the serialized constraint system, enabling
/// circuit-agnostic deserialization:
///
/// ```text
/// [params bytes][vk bytes][cs bytes][footer (32 bytes)]
/// ```
///
/// This allows the VM to deserialize and verify proofs without needing
/// the original circuit type at verification time.
#[proc_macro_attribute]
pub fn cosmwasm_circuit(
    attr: proc_macro::TokenStream,
    item: proc_macro::TokenStream,
) -> proc_macro::TokenStream {
    cosmwasm_circuit::cosmwasm_circuit_impl(attr.into(), item.into())
        .unwrap_or_else(|err| err)
        .into()
}
