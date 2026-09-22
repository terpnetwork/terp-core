# CosmWasm ZK Circuit Serialization Format

## Overview

The serialization format defines how halo2 verifying keys, constraint systems, and commitment parameters are encoded for storage and transmission in CosmWasm. The format embeds the **complete constraint system** (gates, polynomial expressions, permutation argument), enabling circuit-agnostic deserialization and proof verification without access to the original Rust circuit type.

A key design property is **param/vk separation**: the commitment parameters are stored and loaded independently from the constraint system + verifying key. This allows the cache layer to avoid holding the full 65KB+ parameters in memory alongside every VK — the params are deduplicated at the storage level and reconstructed only when needed.

## Design Principles

- **Self-Describing**: All metadata needed for deserialization is embedded in the 80-byte footer
- **Complete CS**: The full constraint system is serialized, including gates and polynomial expressions
- **Circuit-Agnostic Verification**: Proofs can be verified using only the serialized data — no original circuit type required
- **Dual Integrity**: Separate SHA256 checksums protect the param bytes and the (cs+vk) body bytes
- **Content-Addressed**: Each component (params, cs+vk, full circuit) is identified by a composite key derived from the footer's checksums

## Complete Binary Format

```
┌─────────────────────────────────────────────────────┐
│ Halo2 Commitment Parameters (Variable Size)         │
│ - k (circuit size parameter, u32 LE)                │
│ - g (generator commitments)                         │
│ - g_lagrange                                        │
│ - w, u (window/u parameters)                        │
│ Typical size: 60-70 KB for k=10                     │
└─────────────────────────────────────────────────────┘
         param_len bytes (from footer)

┌─────────────────────────────────────────────────────┐
│ Serialized Constraint System (Variable Size)        │
│ - Column counts and queries                         │
│ - Gates with polynomial expressions                 │
│ - Lookups                                           │
│ - Permutation argument                              │
│ - Selector map                                      │
│ Typical size: 200-2000 bytes depending on circuit   │
└─────────────────────────────────────────────────────┘
         cs_len bytes (from footer)

┌─────────────────────────────────────────────────────┐
│ Halo2 Verifying Key (Variable Size)                 │
│ - Fixed column commitments                          │
│ - Permutation verifying key                         │
│ Typical size: 300-500 bytes                         │
└─────────────────────────────────────────────────────┘
         vk_len bytes (from footer)

┌─────────────────────────────────────────────────────┐
│ CosmWasm ZK Footer Metadata (80 bytes)              │
│ Section lengths, metadata, dual SHA256 checksums    │
└─────────────────────────────────────────────────────┘
```

**Section ordering**: Params, then CS, then VK, then footer. This matches the serialization order in `to_bytes_with_params()` and the deserialization order in `from_bytes_without_params()`.

**File on disk**: The full circuit blob is stored as a single file under `zk_circuit/` (the monolithic fallback). The split components are stored under `zk_param/` (params only) and `zk_vk/` (cs + vk, no footer).

## Footer Metadata Structure (80 Bytes)

The footer is a single unified metadata object that contains section lengths, circuit metadata, and **two independent SHA256 checksums**.

### Byte Layout

| Offset | Size | Field | Type | Purpose |
|--------|------|-------|------|---------|
| 0 | 1 | `prover_id` | `u8` | Proving system identifier (0 = Plonkish) |
| 1 | 1 | `curve_id` | `u8` | Curve identifier (0 = Pasta) |
| 2 | 1 | `k` | `u8` | K element in circuit constraint system |
| 3 | 1 | `i` | `u8` | Number of public input scalars required |
| 4-7 | 4 | `param_len` | `u32` LE | Byte length of commitment params section |
| 8-11 | 4 | `cs_len` | `u32` LE | Byte length of constraint system section |
| 12-15 | 4 | `vk_len` | `u32` LE | Byte length of verifying key section |
| 16-47 | 32 | `param_checksum` | `[u8; 32]` | SHA256 of the param bytes alone |
| 48-79 | 32 | `vk_checksum` | `[u8; 32]` | SHA256 of the cs + vk bytes alone |

**Interpreting `appstate_key`**: The first 4 bytes (prover_id, curve_id, k, zero) are combined into a u32 `appstate_key()` via `u32::from_be_bytes(...)`. This value is used as the prefix when constructing file keys for the split storage layout.

### File Key Derivation

Each component (params, vk, full circuit) is stored under a **content-addressed key** that combines the appstate identifier with the component's SHA256 checksum:

```
param_key  = [4-byte appstate_key_le][32-byte param_checksum]  → 36 bytes
vk_key     = [4-byte appstate_key_le][32-byte vk_checksum]     → 36 bytes
circuit_key = [param_key][vk_key]                                → 72 bytes
```

This is implemented in `CircuitFooter::to_param_key()`, `to_vk_key()`, and `to_circuit_key()`.

## Serialization and Deserialization

### Serialization Process

When writing a circuit's verifying key and constraint system for CosmWasm storage:

1. Generate verifying key using `plonk::keygen_vk(&params, &circuit)`
2. Serialize params to byte buffer using `params.write()` → `buf1`
3. Serialize constraint system to byte buffer using `vk.cs().write()` → `buf2`
4. Serialize verifying key to byte buffer using `vk.write()` → `buf3`
5. Compute SHA256 of `buf1` → `param_checksum`
6. Compute SHA256 of `buf2 || buf3` → `vk_checksum`
7. Create `CircuitFooter` with section lengths and both checksums
8. Concatenate: `buf1 || buf2 || buf3 || footer.to_bytes()` (80 bytes)
9. Store the combined blob and/or the split components

### Deserialization Process (Combined Monolithic File)

1. Read entire file into memory
2. Extract and parse the last 80 bytes as `CircuitFooter`
3. Validate both checksums using `check_circuit()`:
   - `SHA256(bytes[0..param_len]) == footer.param_checksum`
   - `SHA256(bytes[param_len..param_len+cs_len+vk_len]) == footer.vk_checksum`
4. Read params from `bytes[0..param_len]` using `Params::read()`
5. Read constraint system from `bytes[param_len..param_len+cs_len]` using `ConstraintSystem::read()`
6. Read verifying key from `bytes[param_len+cs_len..param_len+cs_len+vk_len]` using `VerifyingKey::read_with_cs()`
7. Install `CsBlueprint` from the deserialized CS (for DynamicCircuit compatibility)
8. Return complete `CwVerifyingKey` with params, VK, and footer

### Deserialization Process (Split Param/VK Files)

When loading from the split cache layout:

1. Load param bytes from `zk_param/{param_key}.bin`
2. Load cs+vk bytes from `zk_vk/{vk_key}.bin`
3. Load footer from the monolithic circuit blob under `zk_circuit/`
4. Validate `param_len` matches param file size
5. Validate `cs_len + vk_len` matches vk body file size
6. Validate both SHA256 checksums
7. Call `AnyVerifyingKey::from_split_bytes(param_bytes, vk_body_bytes, &footer)`:
   - Reads params from `param_bytes` using `Params::read()`
   - Reads CS from `vk_body_bytes[0..cs_len]` using `ConstraintSystem::read()`
   - Reads VK from `vk_body_bytes[cs_len..cs_len+vk_len]` using `VerifyingKey::read_with_cs()`
8. Return complete `CwVerifyingKey`

## Core Data Structures

### CircuitFooter (80 bytes)

- **Location**: `packages/zk/src/footer.rs`
- **Struct Name**: `CircuitFooter`
- **Key Methods**:
  - `new()`: Create footer with all metadata and both checksums
  - `to_bytes()`: Serialize to exactly 80 bytes
  - `from_bytes()`: Deserialize from 80 bytes
  - `to_param_key()`: 36-byte key for param file storage
  - `to_vk_key()`: 36-byte key for vk file storage
  - `to_circuit_key()`: 72-byte compound key for monolithic circuit storage
  - `appstate_key()`: 4-byte u32 identifier for the circuit/curve combination

### CwVerifyingKey / CwCircuit

- **Location**: `packages/zk/src/circuits.rs`
- **Structs**:
  - `CwVerifyingKey<C>`: Holds `params: C::Params`, `vk: C::VerifyingKey`, `footer: CircuitFooter`
  - `CwCircuit<C>`: Holds the same fields but with `pub` visibility (for external consumers)
  - `CwCircuitParam<C>`: Wrapper around `C::Params` for isolated param storage
  - `CwConstraintSystem<C>`: Wrapper around `C::ConstraintSystem`

### AnyVerifyingKey (Variant Enum)

- **Location**: `packages/zk/src/circuits.rs`
- **Variants**: `Vesta(VestaVerifyingKey)`
- **Key Methods**:
  - `from_bytes(bytes)` — Monolithic deserialization (params + cs + vk + footer)
  - `from_split_bytes(param_bytes, vk_body_bytes, footer)` — Split deserialization
  - `to_bytes_with_params()` — Serialize to monolithic format
  - `verify(proof, instances)` — Verify a proof against this key

### SerializedCircuitData

- **Location**: `packages/zk/src/circuits.rs`
- **Fields**: `body: Vec<u8>`, `footer: Vec<u8>`
- **Purpose**: Intermediate representation used when loading from disk and passing through the cache layer. The body is params + cs + vk (without footer), and the footer is the raw 80-byte footer bytes.

## Integrity Validation

The `check_circuit()` function in `packages/vm/src/zk.rs` validates:

- ✓ File size is at least 80 bytes (COSMWASM_FOOTER_LENGTH)
- ✓ Footer parses as valid `CircuitFooter`
- ✓ `param_checksum == SHA256(bytes[0..param_len])`
- ✓ `vk_checksum == SHA256(bytes[param_len..param_len+cs_len+vk_len])`

These checks are performed on every load from disk (both monolithic and split paths). The split path additionally validates file sizes match the footer's section lengths.

## FFI Binary Format (for wasmvm integration)

When circuit data is transmitted via the C/Rust/Go boundary, the `SerializedCircuitData` is transmitted as a simple concatenation of body + footer:

```
[body: N bytes]    ← params + cs + vk (no footer)
[footer: 80 bytes] ← raw CircuitFooter bytes
```

**Serialization** (Rust → FFI):

- **Function**: `cosmwasm_vm::zk::serialize_circuit_data()`
- **Input**: `&SerializedCircuitData`
- **Output**: `Vec<u8>` — body bytes followed by footer bytes

**Deserialization** (FFI → Rust):

- **Function**: `cosmwasm_vm::zk::deserialize_circuit_data()`
- **Input**: `&[u8]`
- **Output**: `ZkResult<SerializedCircuitData>`
- Splits at `len - 80` to separate body and footer

## Related Code Locations

| Component | Location |
|-----------|----------|
| `CircuitFooter` struct and implementation | `packages/zk/src/footer.rs` |
| `AnyVerifyingKey`, `CwVerifyingKey`, `CwCircuit` | `packages/zk/src/circuits.rs` |
| `SerializedCircuitData` | `packages/zk/src/circuits.rs` |
| `DynamicCircuit` (v1 compat) | `packages/zk/src/circuits.rs` |
| `CsBlueprint`, `CsBlueprintGuard` | `packages/zk/src/circuits.rs` |
| `check_circuit()` validation | `packages/vm/src/zk.rs` |
| `serialize_circuit_data()` / `deserialize_circuit_data()` | `packages/vm/src/zk.rs` |
| `VestaVerifyingKey` (vesta curve impl) | `packages/zk/src/curves/vesta.rs` |
| `ZkCurve` trait | `packages/zk/src/curves.rs` |
| `CachedCircuit`, `CachedParam` | `packages/vm/src/modules/cached_module.rs` |
| Cache storage/split logic | `packages/vm/src/cache.rs` |
| File system cache (circuit methods) | `packages/vm/src/modules/file_system_cache.rs` |
| In-memory LRU cache | `packages/vm/src/modules/in_memory_cache.rs` |
| Pinned memory cache | `packages/vm/src/modules/pinned_memory_cache.rs` |
| `COSMWASM_FOOTER_LENGTH` constant | `halo2_proofs/src/lib.rs` |
| `ConstraintSystem::write()/read()` | `halo2_proofs/src/plonk/circuit.rs` |
| `VerifyingKey::read_with_cs()` | `halo2_proofs/src/plonk/keygen.rs` |

## Performance Characteristics

| Operation | Typical Time | Notes |
|-----------|------|-------|
| Parse footer | <1 μs | Last 80 bytes only |
| Validate both checksums | <1 μs | Two SHA256 hashes |
| Create DynamicCircuit | <1 ms | Thread-local CsBlueprint setup |
| Deserialize params | 10-100 ms | k-dependent (k=10 ≈ 65KB) |
| Deserialize CS | 1-5 ms | Gate count dependent |
| Deserialize VK | 50-200 ms | Column/permutation dependent |
| Load from pinned cache | <1 μs | HashMap lookup by 72-byte key |
| Load from FS cache | 1-10 ms | Deserialize from cached wasmer module |
| Load from disk (split) | 100-400 ms | Two file reads + full deserialization |
| Load from disk (monolithic) | 100-400 ms | One file read + full deserialization |