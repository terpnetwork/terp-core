# CosmWasm Circuit Macro - Enhanced Reference with Constraint System Support

**Last Updated**: 2025-01-06  
**Status**: Updated for Version 2.0 (CS-Inclusive Serialization)  
**Version**: 2.0  

---

## Table of Contents

1. [Overview](#overview)
2. [Key Enhancements in Version 2.0](#key-enhancements-in-version-20)
3. [Implementation Architecture](#implementation-architecture)
4. [Trait Definition](#trait-definition)
5. [Macro Attributes](#macro-attributes)
6. [Circuit Analysis](#circuit-analysis)
7. [Code Generation](#code-generation)
8. [Usage Examples](#usage-examples)
9. [Validation Rules](#validation-rules)
10. [Generated Methods](#generated-methods)
11. [Error Handling](#error-handling)
12. [Testing](#testing)

---

## Overview

The `#[cosmwasm_circuit]` derive macro enables ZK circuit developers to create circuits compatible with the CosmWasm VM by **automatically generating serialization logic, footer metadata, and constraint system analysis** for the full pinned constraint system.

### Key Features

- **Automatic Circuit Analysis**: Inspects `Circuit::configure()` to extract column counts, gates, selectors, and permutation data
- **Footer Generation**: Auto-creates `CircuitFooter` with computed metadata (Version 2 format)
- **Full Serialization**: Generates `to_bytes_with_cs()` for complete circuit serialization including CS
- **Compile-time Validation**: Validates CS properties and serialization compatibility
- **VM Integration**: Seamless integration with Version 2 serialization format
- **Zero Runtime Overhead**: All analysis and generation happens at compile time

### Architecture Overview

```
Macro Entry Point (lib.rs)
    ↓
Attribute Parser (parsers.rs)
    ↓
Circuit Analyzer (circuit_analyzer.rs) [NEW]
    ↓
CS Metadata Extraction (metadata_extractor.rs) [NEW]
    ↓
Validators (validators.rs) [enhanced]
    ↓
Serialization Code Gen (serialization_generator.rs) [NEW]
    ↓
Trait + Constants Generated
```

---

## Key Enhancements in Version 2.0

### Automatic Constraint System Analysis

- **Column Counting**: Automatically determines fixed, advice, and instance column counts from `configure()`
- **Gate/Selector Analysis**: Extracts gate count, selector mappings, and polynomial expressions
- **Permutation Detection**: Identifies columns participating in copy constraints
- **Lookup Validation**: Detects and validates lookup argument presence

### Footer and Metadata Auto-Generation

- **CircuitFooter Creation**: Generates Version 2 footer with computed checksums and lengths
- **Serialization Methods**: Auto-implements `to_bytes_with_cs()` and related methods
- **Metadata Constants**: Creates compile-time constants for CS properties

### Enhanced Trait Interface

- **Serialization Support**: New methods for VM-compatible serialization
- **CS Metadata Access**: Methods to inspect analyzed constraint system properties
- **FFI Integration**: Methods for WASM boundary transmission
- **Automatic Derivation**: All metadata values computed from circuit analysis, not hardcoded

---

## Implementation Architecture

### Directory Structure

```
packages/vm/src/
├── zk.rs                    # Enhanced trait definition and types

packages/vm-derive/src/
├── lib.rs                   # Macro registration
├── cosmwasm_circuit.rs      # Main macro orchestration
├── parsers.rs               # Attribute parsing
├── validators.rs            # Constraint validation
├── code_generators.rs       # Code generation
├── circuit_analyzer.rs      # Circuit analysis logic [NEW]
├── metadata_extractor.rs    # CS metadata extraction [NEW]
├── serialization_generator.rs # Serialization code gen [NEW]
└── hash_function.rs         # Existing hash macro
```

### Component Responsibilities

#### circuit_analyzer.rs [NEW]

- Executes `Circuit::configure()` in isolation to extract `PinnedConstraintSystem`
- Counts columns, gates, selectors across different types
- Analyzes permutation arguments and lookup structures
- Validates CS internal consistency

#### metadata_extractor.rs [NEW]

- Builds `ConstraintSystemMetadata` from analyzed CS
- Computes derived properties (degree, permutation masks)
- Validates metadata against macro attributes

#### serialization_generator.rs [NEW]

- Generates `to_bytes_with_cs()` implementation
- Creates footer generation code with checksums
- Handles CS serialization integration

---

## Trait Definition

The `CosmwasmCircuitFor` trait is enhanced with serialization and CS analysis capabilities.

```rust
/// Metadata about a circuit's constraint system
#[derive(Debug, Clone)]
pub struct ConstraintSystemMetadata {
    pub num_fixed_columns: u32,
    pub num_advice_columns: u32,
    pub num_instance_columns: u32,
    pub num_selectors: u32,
    pub num_gates: u32,
    pub degree: u8,
    pub has_lookups: bool,
    pub permutation_columns: Vec<Column>,
}

/// Enhanced trait with CS analysis and serialization support
pub trait CosmwasmCircuitFor<C: Circuit<vesta::Scalar>> {
    // Existing methods...
    fn circuit_metadata() -> PlonkishCircuitMetadata;
    fn verifying_key() -> VerifyingKey;
    fn instance_count() -> u8;
    fn k_parameter() -> u32;
    fn is_compatible(i: &[vesta::Scalar]) -> bool;
    
    // New CS and serialization methods
    fn constraint_system_metadata() -> ConstraintSystemMetadata;
    fn footer() -> CircuitFooter;
    fn to_bytes_with_cs() -> Result<Vec<u8>, Error>;
    fn from_bytes_with_cs(bytes: &[u8]) -> Result<VerifyingKey, Error>;
    fn serialize_for_vm() -> SerializedCircuitData;
}
```

---

## Macro Attributes

### Required Attributes

| Attribute | Type | Range | Description |
|-----------|------|-------|-------------|
| `k` | u32 | 11-20 | Circuit size (2^k rows) |
| `instances` | u8 | 1-255 | Number of public inputs |

### Optional Attributes

| Attribute | Type | Default | Description |
|-----------|------|---------|-------------|
| `circuit_type` | CircuitType enum | `Plonkish` | Serialization format variant |
| `footer_version` | u8 | `2` | Footer format version |
| `analyze_cs` | bool | `true` | Whether to perform CS analysis |

### Attribute Validation

```sh
k, instances: (unchanged)

circuit_type:
  - Must be known (Plonkish, etc.)

footer_version:
  - Must be >= 2 for CS support

analyze_cs:
  - If true, performs full CS analysis
  - If false, skips analysis (legacy mode)
```

---

## Circuit Analysis

### Analysis Process

1. **Configuration Execution**: Macro creates a temporary circuit instance and calls `configure()`
2. **CS Extraction**: Captures the resulting `PinnedConstraintSystem`
3. **Property Extraction**: Counts columns, gates, selectors by type
4. **Validation**: Checks CS internal consistency and attribute compatibility

### Extracted Properties

- **Column Counts**: Fixed, advice, instance columns in permutation
- **Gate Metadata**: Gate count, selector mappings, polynomial degrees
- **Permutation Info**: Columns participating in copy constraints
- **Lookup Detection**: Presence and structure of lookup arguments

### Analysis Output

```rust
pub struct CircuitAnalysis {
    pub cs_metadata: ConstraintSystemMetadata,
    pub footer_params: FooterParameters,
    pub validation_errors: Vec<String>,
}
```

### Derivation Process

The macro performs compile-time analysis to extract all metadata values:

1. **Column Counting**: Analyzes `PinnedConstraintSystem` to count fixed, advice, and instance columns
2. **Selector Analysis**: Counts selectors and builds selector-to-fixed-column mappings
3. **Gate Counting**: Counts gate definitions and analyzes polynomial expressions for degree
4. **Permutation Extraction**: Identifies columns participating in copy constraints
5. **Lookup Detection**: Scans for lookup argument definitions
6. **Degree Computation**: Finds maximum polynomial degree across all constraints

All values are computed dynamically based on the circuit's `configure()` method implementation.

---

## Code Generation

### What Gets Generated

For a circuit annotated with `#[cosmwasm_circuit(k = 17, instances = 2)]`:

#### 1. Enhanced Trait Implementation

```rust
impl cosmwasm_vm::zk::CosmwasmCircuitFor<MyCircuit> {
    // Existing methods...
    
    pub fn constraint_system_metadata() -> cosmwasm_vm::zk::ConstraintSystemMetadata {
        // Auto-generated from circuit analysis of configure() method
        // Values are dynamically extracted at compile time
        cosmwasm_vm::zk::ConstraintSystemMetadata {
            num_fixed_columns: /* extracted from PinnedConstraintSystem */,
            num_advice_columns: /* extracted from PinnedConstraintSystem */,
            num_instance_columns: /* extracted from PinnedConstraintSystem */,
            num_selectors: /* counted from selector mappings */,
            num_gates: /* counted from gate definitions */,
            degree: /* computed from polynomial degrees */,
            has_lookups: /* detected from lookup arguments */,
            permutation_columns: /* extracted from permutation argument */,
        }
    }

    pub fn footer() -> cosmwasm_vm::zk::CircuitFooter {
        // Auto-generated footer with dynamically computed values
        // All parameters derived from circuit analysis
        let cs_meta = Self::constraint_system_metadata();

        cosmwasm_vm::zk::CircuitFooter::new(
            cosmwasm_vm::zk::CircuitType::Plonkish,
            Self::instance_count(),
            cs_meta.num_fixed_columns as u8,
            cs_meta.num_advice_columns as u8,
            cs_meta.num_instance_columns as u8,
            cs_meta.degree,
            2, // version
            1, // flags (HAS_CS)
            /* computed lengths from serialization */,
            /* computed checksum */,
        )
    }

    pub fn to_bytes_with_cs() -> Result<Vec<u8>, cosmwasm_vm::zk::Error> {
        // Auto-generated serialization
        let circuit = Self::without_witnesses();
        let params = cosmwasm_vm::zk::Params::<pasta_curves::vesta::Affine>::new(17);
        
        let mut cs = halo2_proofs::plonk::ConstraintSystem::<pasta_curves::vesta::Scalar>::default();
        circuit.configure(&mut cs);
        let pinned_cs = cs.pinned();
        
        let params_bytes = /* serialize params */;
        let vk_bytes = /* serialize vk */;
        let cs_bytes = /* serialize cs */;
        let footer_bytes = Self::footer().to_bytes();
        
        Ok([params_bytes, vk_bytes, cs_bytes, footer_bytes].concat())
    }

    pub fn serialize_for_vm() -> cosmwasm_vm::zk::SerializedCircuitData {
        // Auto-generated FFI format
        let bytes = Self::to_bytes_with_cs().unwrap();
        let hash = /* compute SHA256 */;
        cosmwasm_vm::zk::SerializedCircuitData {
            bytes,
            hash,
            metadata: Self::footer().to_bytes(),
        }
    }
}
```

#### 2. Compile-time Constants

```rust
pub const MYCIRCUIT_CS_METADATA: cosmwasm_vm::zk::ConstraintSystemMetadata = /* ... */;
pub const MYCIRCUIT_FOOTER: cosmwasm_vm::zk::CircuitFooter = /* ... */;
```

---

## Usage Examples

### Basic Usage with Automatic Serialization

```rust
#[cosmwasm_circuit(k = 17, instances = 2)]
pub struct MyCircuit {
    secret: Option<vesta::Scalar>,
}

impl Circuit<vesta::Scalar> for MyCircuit {
    // Standard halo2 implementation
}

// Now automatically available:
let cs_meta = MyCircuit::constraint_system_metadata();
let footer = MyCircuit::footer();
let serialized = MyCircuit::to_bytes_with_cs()?;
let vm_data = MyCircuit::serialize_for_vm();

// Contract integration
#[entry_point]
pub fn verify_proof(deps: DepsMut, msg: VerifyMsg) -> StdResult<Response> {
    let vk = MyCircuit::verifying_key();
    // or deserialize from stored bytes:
    let vk = MyCircuit::from_bytes_with_cs(&stored_bytes)?;
    
    msg.proof.verify(&vk, &msg.instances)?;
    Ok(Response::new().add_attribute("verified", "true"))
}
```

### Advanced Usage with Metadata Inspection

```rust
#[test]
fn test_circuit_properties() {
    let meta = MyCircuit::constraint_system_metadata();
    // Values are automatically derived from circuit analysis - test your circuit's actual values
    assert_eq!(meta.num_advice_columns, 2); // Example: adjust based on your circuit
    assert_eq!(meta.degree, 2);             // Example: adjust based on your circuit
    assert!(!meta.has_lookups);            // Example: adjust based on your circuit

    let footer = MyCircuit::footer();
    assert_eq!(footer.footer_version, 2);
    assert!(footer.flags & 1 != 0); // HAS_CS flag set
}
```

---

## Validation Rules

### At Compile Time

✅ **Validated by the macro:**

- `k`, `instances` (unchanged)
- `circuit_type`, `footer_version` known and valid
- **Circuit analysis succeeds** without errors
- **CS properties consistent** with macro attributes
- **Column counts valid** for permutation arguments
- **Degree within halo2 limits** (1-126)

❌ **NOT validated (runtime responsibility):**

- Circuit implements `Circuit<vesta::Scalar>`
- Actual public input count matches `instances`
- Circuit logic correctness

---

## Generated Methods

### constraint_system_metadata() -> ConstraintSystemMetadata

Returns analyzed metadata about the circuit's constraint system.

```rust
pub fn constraint_system_metadata() -> ConstraintSystemMetadata;
```

### footer() -> CircuitFooter

Returns the auto-generated circuit footer for serialization.

```rust
pub fn footer() -> CircuitFooter;
```

### to_bytes_with_cs() -> Result<Vec<u8>, Error>

Serializes the complete circuit (params + vk + cs + footer) for storage.

```rust
pub fn to_bytes_with_cs() -> Result<Vec<u8>, Error>;
```

### from_bytes_with_cs(bytes: &[u8]) -> Result<VerifyingKey, Error>

Deserializes a complete circuit and returns a verifying key ready for proof verification.

```rust
pub fn from_bytes_with_cs(bytes: &[u8]) -> Result<VerifyingKey, Error>;
```

### serialize_for_vm() -> SerializedCircuitData

Returns circuit data in FFI-ready format for WASM transmission.

```rust
pub fn serialize_for_vm() -> SerializedCircuitData;
```

---

## Error Handling

### New Analysis Errors

```bash
error: Circuit analysis failed: configure() method not found
  --> src/lib.rs:5:1
    |
  5 | #[cosmwasm_circuit(k = 17, instances = 2)]
    | ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    = note: Ensure the struct implements Circuit<vesta::Scalar>

error: CS validation failed: declared 2 advice columns but configure() creates 3
  --> src/lib.rs:5:1
    |
  5 | #[cosmwasm_circuit(k = 17, instances = 2)]
    | ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    = note: Check your circuit's configure() method
```

### Serialization Errors

Runtime errors in generated methods:

- `CircuitAnalysisError`: CS analysis failures
- `SerializationError`: Binary serialization issues
- `FooterGenerationError`: Footer creation problems

---

## Testing

### Macro Expansion Testing

```bash
cargo expand --lib packages/vm-derive
```

### Unit Tests

```rust
#[test]
fn test_cs_metadata() {
    let meta = TestCircuit::constraint_system_metadata();
    // Values automatically derived from circuit analysis
    assert_eq!(meta.num_gates, 3);     // Example: adjust based on your circuit
    assert_eq!(meta.degree, 2);        // Example: adjust based on your circuit
}

#[test]
fn test_serialization_roundtrip() {
    let original = TestCircuit::verifying_key();
    let bytes = TestCircuit::to_bytes_with_cs().unwrap();
    let deserialized = TestCircuit::from_bytes_with_cs(&bytes).unwrap();
    
    // Verify they produce the same verification results
    assert_eq!(original.i, deserialized.i);
}
```

---

## Performance Characteristics

### Compile Time

- **Circuit Analysis**: ~100-500ms per circuit (one-time)
- **Code Generation**: ~50-200ms additional
- **Total Overhead**: ~200-800ms per annotated circuit

### Runtime

- **Metadata Access**: <1μs (compile-time constants)
- **Serialization**: ~500-2000ms (circuit-dependent)
- **Deserialization**: ~200-1000ms (CS parsing overhead)

---

## Backward Compatibility

- Existing circuits without `analyze_cs = false` get full analysis
- Old macro usage remains valid
- Version detection in serialized data
- Fallback to DynamicCircuit for version 1 files

---

## Future Extensions

1. **Dynamic Circuit Support**: Analysis for circuits with runtime configuration
2. **Optimization Hints**: Attributes for serialization optimization
3. **Circuit Composition**: Metadata aggregation for composite circuits
4. **Version Negotiation**: Automatic version selection based on VM capabilities

---

## Summary

Version 2.0 of the `#[cosmwasm_circuit]` macro provides **automatic constraint system analysis and serialization generation**, enabling circuit developers to focus on ZK logic while the macro handles all VM integration details.

**All metadata values are pragmatically derived from circuit analysis - no hardcoding required. The macro builds a complete, self-describing circuit representation automatically.**

---

## Implementation Source

- `packages/vm/src/zk.rs` - Enhanced trait and types
- `packages/vm-derive/src/` - Macro implementation:
  - `circuit_analyzer.rs` - Circuit analysis [NEW]
  - `metadata_extractor.rs` - CS metadata [NEW]  
  - `serialization_generator.rs` - Serialization code [NEW]
  - `cosmwasm_circuit.rs` - Main orchestration [ENHANCED]

**Documentation Updated**: 2025-01-06  
**Version**: 2.0  
**Status**: Ready for Implementation

---
