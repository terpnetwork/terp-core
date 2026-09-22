use proc_macro2::TokenStream;
use quote::quote;

use crate::parsers::CircuitAttributes;

/// Generates Rust code for a circuit based on its attributes
///
/// This generator creates the trait implementation for `CosmwasmCircuitFor<T>`
/// including constraint system analysis, footer generation, and serialization support.
pub struct CodeGenerator {
    circuit_name: syn::Ident,
    attrs: CircuitAttributes,
}

impl CodeGenerator {
    /// Create a new code generator
    pub fn new(circuit_name: syn::Ident, attrs: CircuitAttributes) -> Self {
        CodeGenerator {
            circuit_name,
            attrs,
        }
    }

    /// Generate the complete macro implementation
    pub fn generate(&self) -> TokenStream {
        let trait_impl = self.generate_trait_impl();
        let constants = self.generate_constants();

        quote! {
            #trait_impl
            #constants
        }
    }

    /// Generate CosmwasmCircuitFor<T> trait implementation
    ///
    /// This generates all the methods specified in the trait:
    /// - circuit_metadata() - basic circuit metadata
    /// - verifying_key() - build the VK
    /// - instance_count() - public input count
    /// - k_parameter() - circuit size
    /// - is_compatible() - validate instances
    /// - constraint_system_metadata() - CS analysis results
    /// - footer() - CircuitFooter for serialization
    /// - to_bytes_with_cs() - full serialization
    /// - from_bytes_with_cs() - deserialization
    /// - serialize_for_vm() - FFI format
    fn generate_trait_impl(&self) -> TokenStream {
        let circuit_name = &self.circuit_name;
        let k = self.attrs.k;
        let instances = self.attrs.instances;
        let ct_byte = self.attrs.circuit_type.to_u8();
        let _analyze_cs = self.attrs.analyze_cs;
        let cs_metadata_impl = self.generate_cs_metadata_impl();
        let footer_impl = self.generate_v2_footer_impl();
        let serialization_impl = self.generate_v2_serialization_impl();

        quote! {
            /// Automatically generated trait implementation for CosmWasm circuit compatibility
            impl cosmwasm_vm::zk::CosmwasmCircuitFor<#circuit_name> {
                /// Get metadata about this circuit
                pub fn circuit_metadata() -> cosmwasm_vm::zk::PlonkishCircuitMetadata {
                    cosmwasm_vm::zk::PlonkishCircuitMetadata {
                        ct: cosmwasm_vm::zk::CircuitType::from_u8(#ct_byte)
                            .expect("Valid circuit type"),
                        i: #instances,
                        name: stringify!(#circuit_name),
                    }
                }

                /// Build the verifying key for this circuit
                pub fn verifying_key() -> cosmwasm_vm::zk::VerifyingKey {
                    let circuit = <#circuit_name as halo2_proofs::plonk::Circuit<pasta_curves::vesta::Scalar>>::without_witnesses(
                        &#circuit_name::default()
                    );
                    cosmwasm_vm::zk::VerifyingKey::build(circuit, #k, #instances as usize)
                }

                /// Get the circuit type
                pub fn ct() -> cosmwasm_vm::zk::CircuitType {
                    cosmwasm_vm::zk::CircuitType::from_u8(#ct_byte)
                        .expect("Valid circuit type")
                }

                /// Get the instance count
                pub fn instance_count() -> u8 {
                    #instances
                }

                /// Get the k parameter (circuit size = 2^k rows)
                pub fn k_parameter() -> u32 {
                    #k
                }

                /// Validate instance compatibility
                pub fn is_compatible(i: &[pasta_curves::vesta::Scalar]) -> bool {
                    i.len() == #instances as usize
                }

                #cs_metadata_impl

                #footer_impl

                #serialization_impl
            }
        }
    }

    /// Generate constraint_system_metadata() that dynamically analyzes the circuit
    fn generate_cs_metadata_impl(&self) -> TokenStream {
        let circuit_name = &self.circuit_name;

        quote! {
            /// Get constraint system metadata by analyzing the circuit's configure() method
            ///
            /// This dynamically extracts metadata from the circuit at compile time:
            /// - Column counts (fixed, advice, instance)
            /// - Selector count
            /// - Gate count
            /// - Maximum polynomial degree
            /// - Lookup presence
            /// - Permutation columns
            pub fn constraint_system_metadata() -> cosmwasm_vm::zk::ConstraintSystemMetadata {
                use halo2_proofs::plonk::Circuit;

                // Create a default constraint system and configure it
                let mut cs = halo2_proofs::plonk::ConstraintSystem::<pasta_curves::vesta::Scalar>::default();
                let _ = <#circuit_name as Circuit<pasta_curves::vesta::Scalar>>::configure(&mut cs);

                // Extract metadata from the configured constraint system
                let num_fixed_columns = u32::try_from(cs.num_fixed_columns())
                    .expect("fixed column count exceeds u32");
                let num_advice_columns = u32::try_from(cs.num_advice_columns())
                    .expect("advice column count exceeds u32");
                let num_instance_columns = u32::try_from(cs.num_instance_columns())
                    .expect("instance column count exceeds u32");
                let num_selectors = u32::try_from(cs.num_selectors())
                    .expect("selector count exceeds u32");
                let num_gates = u32::try_from(cs.gate_count()).expect("gate count exceeds u32");
                let degree = u8::try_from(cs.degree()).expect("cs degree exceeds u8");
                let has_lookups = cs.has_lookups();
                let permutation_columns = cs.permutation_columns();

                cosmwasm_vm::zk::ConstraintSystemMetadata {
                    num_fixed_columns,
                    num_advice_columns,
                    num_instance_columns,
                    num_selectors,
                    num_gates,
                    degree,
                    has_lookups,
                    permutation_columns,
                }
            }
        }
    }

    /// Generate version 2 footer implementation with CS analysis
    fn generate_v2_footer_impl(&self) -> TokenStream {
        let _circuit_name = &self.circuit_name;
        let _k = self.attrs.k;
        let instances = self.attrs.instances;
        let ct_byte = self.attrs.circuit_type.to_u8();

        quote! {
            pub fn footer() -> cosmwasm_vm::zk::CircuitFooter {
                let cs_meta = Self::constraint_system_metadata();
                cosmwasm_vm::zk::CircuitFooter::new(
                    cosmwasm_vm::zk::CircuitType::from_u8(#ct_byte).expect("Valid circuit type"),
                    #instances,
                )
            }

            /// Get a complete footer with actual byte lengths
            /// This is called during serialization when lengths are known
            fn footer_with_lengths(
                params_len: u32,
                vk_len: u32,
                cs_len: u32,
                crc32: u32,
            ) -> cosmwasm_vm::zk::CircuitFooter {
                let cs_meta = Self::constraint_system_metadata();
                cosmwasm_vm::zk::CircuitFooter::new(
                    cosmwasm_vm::zk::CircuitType::from_u8(#ct_byte).expect("Valid circuit type"),
                    #instances,
                )
            }
        }
    }

    /// Generate version 2 serialization implementation with CS
    fn generate_v2_serialization_impl(&self) -> TokenStream {
        let circuit_name = &self.circuit_name;
        let k = self.attrs.k;
        let _instances = self.attrs.instances;

        quote! {
            /// Serialize the circuit with constraint system (version 2 format)
            ///
            /// Format: [params bytes][vk bytes][cs bytes][footer (32 bytes)]
            ///
            /// This generates a complete circuit file that can be deserialized
            /// without knowing the original circuit type, using the embedded CS.
            pub fn to_bytes() -> Result<Vec<u8>, cosmwasm_vm::zk::ZkError> {
                use std::io::Write;
                use halo2_proofs::plonk::Circuit;

                // Build circuit and generate keys
                let circuit = <#circuit_name as Circuit<pasta_curves::vesta::Scalar>>::without_witnesses(
                    &#circuit_name::default()
                );

                // Create params
                let params = halo2_proofs::poly::commitment::Params::<pasta_curves::vesta::Affine>::new(#k);

                // Serialize params
                let mut params_buf = Vec::new();
                params.write(&mut params_buf)
                    .map_err(|e| cosmwasm_vm::zk::ZkError::new_err(format!("Failed to serialize params: {}", e)))?;

                // Generate VK
                let vk = halo2_proofs::plonk::keygen_vk(&params, &circuit)
                    .map_err(|e| cosmwasm_vm::zk::ZkError::new_err(format!("Failed to generate VK: {:?}", e)))?;

                // Serialize VK
                let mut vk_buf = Vec::new();
                vk.write(&mut vk_buf)
                    .map_err(|e| cosmwasm_vm::zk::ZkError::new_err(format!("Failed to serialize VK: {}", e)))?;

                // // Get the constraint system and serialize it
                // let mut cs = halo2_proofs::plonk::ConstraintSystem::<pasta_curves::vesta::Scalar>::default();
                // let _ = <#circuit_name as Circuit<pasta_curves::vesta::Scalar>>::configure(&mut cs);

                // let mut cs_buf = Vec::new();
                // cs.write(&mut cs_buf)
                //     .map_err(|e| cosmwasm_vm::zk::ZkError::new_err(format!("Failed to serialize CS: {}", e)))?;



                let paramlen =  params_buf.len();
                let vklen = vk_buf.len();
                let mut output = Vec::with_capacity(paramlen + vklen  + COSMWASM_FOOTER_LENGTH);
                // write to output buffer, pad with known object len in ZcashDeserialize fashion
                output.extend_from_slice(&[paramlen])
                output.extend_from_slice(&params_buf);
                output.extend_from_slice(&[vklen])
                output.extend_from_slice(&vk_buf);
                output.extend_from_slice(&CircuitFooter::new(instances,Sha256::digest(output).into()).to_bytes());

                Ok(output)
            }

            /// Deserialize a verifying key from bytes (version 2 format with CS)
            ///
            /// This uses the embedded constraint system for circuit-agnostic deserialization.
            pub fn from_bytes(bytes: &[u8]) -> Result<cosmwasm_vm::zk::VerifyingKey, cosmwasm_vm::zk::ZkError> {
                cosmwasm_vm::zk::VerifyingKey::from_bytes(bytes)
            }

        }
    }

    /// Generate compile-time constants
    fn generate_constants(&self) -> TokenStream {
        let circuit_name = &self.circuit_name;
        let const_prefix = circuit_name.to_string().to_uppercase();

        let metadata_const_name =
            syn::Ident::new(&format!("{}_METADATA", const_prefix), circuit_name.span());
        let k_const_name = syn::Ident::new(&format!("{}_K", const_prefix), circuit_name.span());
        let instances_const_name =
            syn::Ident::new(&format!("{}_INSTANCES", const_prefix), circuit_name.span());

        let k = self.attrs.k;
        let instances = self.attrs.instances;

        quote! {
            /// Circuit size parameter (2^k rows)
            pub const #k_const_name: u32 = #k;

            /// Number of public inputs
            pub const #instances_const_name: u8 = #instances;

            /// Circuit metadata available at compile time
            pub const #metadata_const_name: cosmwasm_vm::zk::PlonkishCircuitMetadata = cosmwasm_vm::zk::PlonkishCircuitMetadata {
                ct: cosmwasm_vm::zk::CircuitType::Plonkish,
                i: #instances,
                name: stringify!(#circuit_name),
            };
        }
    }
}
