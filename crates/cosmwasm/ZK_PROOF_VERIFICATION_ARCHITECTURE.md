# ZK Proof Verification Architecture: Multi-Circuit Support

## Overview

This document describes the architecture for zero-knowledge proof verification in the CosmWasm VM, enabling support for multiple verification keys (VKs) indexed by **zkid**. The system supports circuit-agnostic verification through version 2 format with embedded constraint systems.

**Key Feature**: Proof verification is invoked via:

```rust
deps.api.proof_instance_verify(zkID: u64, proof: &[u8], instances: &[u8])
```

 allowing contracts to use multiple circuits dynamically.

---

The architecture supports multiple verification keys indexed by application-assigned `zkid` values:

```
AppState (Consensus State)
    └── zkid_to_checksum_mapping
            ├── zkid=1 → Checksum(0xabcd...)
            ├── zkid=2 → Checksum(0xef01...)
            └── zkid=N → Checksum(0x...xyz)

VM Cache Layer (Performance Optimization)
    ├── Pinned Memory Cache
    │   ├── Checksum(0xabcd...) → Arc<VerifyingKey>
    │   ├── Checksum(0xef01...) → Arc<VerifyingKey>
    │   └── Checksum(0x...xyz) → Arc<VerifyingKey>
    ├── File System Cache
    │   ├── Checksum(0xabcd...).bin → Serialized VK bytes
    │   ├── Checksum(0xef01...).bin → Serialized VK bytes
    │   └── Checksum(0x...xyz).bin → Serialized VK bytes
```

**Proof Verification Flow**:

```
do_proof_instance_verify(zkid, proof_bytes, instances_bytes)
    ↓
1. Charge gas for host call
2. Read proof from WASM memory (max 2 MB)
3. Read instances from WASM memory (max 64 KB)
4. Look up zkid in AppState → Get Checksum
    ↓
    ├─ [Pinned Cache Hit] → Get Arc<VerifyingKey> from memory
    └─ [Pinned Cache Miss] → Load from disk, deserialize, pin in memory
    ↓
5. Verify proof with instances against loaded VK
6. Return 0 (valid) or 1 (invalid)
```

---

## Key Components

### 1. AppState Integration

The application layer maintains the zkid-to-checksum mapping:

**Responsibilities**:

- Maintain authoritative mapping of zkid → Checksum
- Persist across blocks (consensus state)
- Validate zkid references at contract execution time

### 2. Imports Layer (`packages/vm/src/imports.rs`)

The `do_proof_instance_verify` function implements the host import:

```rust
pub fn do_proof_instance_verify<
    A: BackendApi + 'static,
    S: Storage + 'static,
    Q: Querier + 'static,
>(
    mut env: FunctionEnvMut<Environment<A, S, Q>>,
    zkid: u64,
    proof_ptr: u32,
    _proof_len: u32,
    instances_ptr: u32,
    _instances_len: u32,
) -> VmResult<u32> {}
```

- **Input**: Accepts `zkid: u64` parameter for circuit selection
- **Lookup**: Resolves zkid to checksum via `env.resolve_zkid_to_checksum(zkid)`
- **VK Loading**: Loads VK from VM cache using the checksum
- **Verification**: Uses version 2 format with embedded constraint systems for circuit-agnostic verification
- **Return Value**: Returns 0 (valid) or 1 (invalid)

### 3. Environment Extension

The `Environment<A, S, Q>` struct provides zkid resolution by querying app state storage:

```rust
// packages/vm/src/environment.rs
pub fn resolve_zkid_to_checksum(&self, zkid: u64) -> Option<Checksum> {}
```

**Storage Responsibilities**:

- **App Layer**: Stores zkid → checksum mappings in consensus state
  - Key format: `zk_circuits:{zkid}` → 32-byte Checksum
- **VM Layer**: Stores actual VK bytes in file system cache
  - Path: `cache/modules/{checksum}.bin` (serialized VK with embedded CS)

---

## Data Flow: Complete Example

### Scenario: Contract calls `api.proof_instance_verify(zkid, proof, instances)`

**Prerequisites**:

- Contract code stored with VK (via `store_code_with_circuit`)
- VK checksum stored in app state under zkid=42
- VK file persisted to VM file system cache

**Execution Steps**:

1. **WASM Call**

   ```wasm
   ;; In contract code
   (call $do_proof_instance_verify
       (i64.const 42)           ; zkid
       (i32.const 0x1000)       ; proof pointer
       (i32.const 0x200000)     ; proof length (2 MB max)
       (i32.const 0x201000)     ; instances pointer
       (i32.const 0x10000))     ; instances length (64 KB max)
   ```

2. **Imports Layer (`do_proof_instance_verify`)**
   - ✓ Charge host call gas
   - ✓ Read proof from WASM memory (max 2 MB)
   - ✓ Read instances from WASM memory (max 64 KB)
   - → Resolve zkid=42 to checksum via `env.resolve_zkid_to_checksum(zkid)`
   - → Load VK from VM cache using checksum

3. **ZKid Resolution (via Environment::resolve_zkid_to_checksum)**

   ```
   Query app state: storage.get(b"zk_circuits:42")
   Response: Checksum::from([0xab, 0xcd, ...])
   ```

4. **VK Loading from VM Cache**

   ```
   Cache lookup: cache.get_pinned_circuit(checksum)
   ├── Hit: Return Arc<VerifyingKey> from pinned memory
   └── Miss: Load from disk, deserialize with embedded CS, pin in memory
   ```

   Uses version 2 format with embedded constraint system for circuit-agnostic verification.

5. **Proof Verification**

   ```rust
   let result = proof.verify(&vk, &[instances])?;
   ```

   Verification uses the loaded VK with embedded constraint system.

6. **Return to WASM**
   - Valid proof: Return `0`
   - Invalid proof: Return `1`

---

## Integration Points

### 1. During Code Upload

Two main methods store circuits in the wasmvm library:

#### `store_code_with_circuit`

```rust
// packages/vm/src/cache.rs
pub fn store_code_with_circuit(
    &self,
    code_bundle: &CodeBundle,
    checked: bool,
    persist: bool,
) -> VmResult<[Checksum; 2]> {}
```

Validates WASM and VK, stores both to file system cache, and pins VK in memory by default.

#### `store_circuit`

```rust
// packages/vm/src/cache.rs
pub fn store_circuit(&self, vk: &[u8], persist: bool) -> VmResult<Checksum> {}
```

Stores VK to file system cache and optionally pins in memory.

**Storage Responsibilities**:

- **App Layer**: Store zkid → checksum mappings in consensus state
  - Key: `zk_circuits:{zkid}` → 32-byte Checksum
- **VM Layer**: Store actual VK bytes in file system cache for performance
  - Path: `cache/modules/{checksum}.bin` (version 2 format with embedded CS)

### 2. During Contract Execution

**WASM Contract** (in CosmWasm contract code):

```rust
// Call the host function to verify proof with specific circuit
let result: u32 = api.proof_instance_verify(
    zkid,          // ← Which circuit to verify against
    &proof_bytes,
    &instance_bytes,
)?;

// result == 0 means proof is valid
// result == 1 means proof is invalid
if result == 0 {
    // Proof verified!
} else {
    // Invalid proof
}
```

**VM Host Import** (implemented in `packages/vm/src/imports.rs`):

```rust
// do_proof_instance_verify flow:
// 1. Resolve zkid to checksum via env.resolve_zkid_to_checksum()
// 2. Load VK from VM cache using cache.get_pinned_circuit()
// 3. Verify proof using VK with embedded constraint system
// 4. Return result (0 = valid, 1 = invalid)
```

---

## Memory Management

### Size Accounting

The cache tracks memory at multiple levels:

| Level | Responsibility | Impact |
|-------|-----------------|--------|
| **Per-VK** | `LoadedVk::actual_size_bytes()` | Gas metering, circuit unpinning |
| **Per-Cache Tier** | `PinnedMemoryCache::size()` | Observability, metrics reporting |
| **Global** | `Environment::total_pinned_circuit_memory()` | Optional resource limits |

### Eviction Policy

VKs are expensive to deserialize but frequently reused, so the system uses pinning for performance:

1. **Pinned Circuits**: Never automatically evicted (manual `unpin` required)
2. **File System**: Persistent backing store, survives restarts
3. **In-Memory LRU**: Not currently used for circuits (modules only)

```rust
// Circuit operations
cache.pin_circuit(&checksum)?;     // Load from disk and pin in memory
cache.unpin_circuit(&checksum)?;   // Remove from memory (stays on disk)
cache.remove_circuit(&checksum)?;  // Delete from disk and unpin
```

---

## Error Handling

### Possible Errors During Verification

```rust
// 1. zkid not found in registry
Err: VmError::generic_err("ZK circuit 42 not found in registry")

// 2. VK not stored in app state storage
Err: VmError::generic_err("VK not stored in app state for circuit 42")

// 3. Storage access error
Err: VmError::generic_err("Storage error loading VK for circuit 42: <backend_error>")

// 4. VK deserialization failed
Err: VmError::generic_err("Failed to deserialize VK for circuit 42: <parse_error>")

// 5. Proof verification failed (not an error!)
Ok(1)  // ← Returns code 1 to indicate invalid proof

// 6. Instance format invalid
Err: VmError::generic_err("bytes length must be multiple of 32")
```

### Contract's Perspective

```rust
// Contract code calling proof verification
match api.proof_instance_verify(zkid, proof, instances) {
    Ok(0) => { /* proof valid */ },
    Ok(1) => { /* proof invalid */ },
    Ok(_) => { /* unexpected return code */ },
    Err(e) => {
        // zkid missing, VK not in storage, deserialization error, or instance format error
    },
}
```

---

## Operational Considerations

### Node Startup & Recovery

**On Node Restart**:

1. File system cache (`.bin` files) survives restart
2. Pinned memory cache is empty (requires explicit re-pin)
3. App state registry maintains zkid → checksum mappings

**Recovery Steps**:

```rust
// Node operator can explicitly re-pin frequently-used VKs
for zkid in [1, 2, 3] {  // hot-path circuits
    if let Some(checksum) = env.resolve_zkid_to_checksum(zkid) {
        cache.pin_circuit(&checksum)?;
    }
}
```

### Monitoring & Metrics

Cache statistics provide operational insight:

```rust
let metrics = cache.metrics();

println!("Pinned memory cache: {} hits, {} entries, {} bytes",
    metrics.stats.hits_pinned_memory_cache,
    metrics.elements_pinned_memory_cache,
    metrics.size_pinned_memory_cache);

println!("File system cache: {} hits, {} elements",
    metrics.stats.hits_fs_cache,
    metrics.elements_memory_cache);

println!("Total misses: {}", metrics.stats.misses);
```

### Circuit Lifecycle

```
[Store Phase]
store_code_with_circuit
  ├─ Validate WASM + VK (version 2 with CS)
  ├─ Store VK to file system cache (.bin)
  ├─ Pin VK in memory (default)
  └─ App state: store zkid → checksum mapping
           ↓
[Use Phase]
do_proof_instance_verify
  ├─ Resolve zkid → checksum (app state)
  └─ Load VK from cache (pinned memory or disk)
           ↓
[Cleanup Phase]
remove_circuit
  ├─ Unpin from memory
  └─ Remove from disk
```

---

## Virtual Memory Principles Applied

Our architecture mirrors operating system virtual memory concepts:

| VM Concept | Our Implementation |
|-----------|-------------------|
| Virtual Address | `zkid` (logical identifier) |
| Page Table | App state zkid → checksum mapping |
| Physical Frame | VK bytes in pinned memory |
| Page Fault | Cache miss → load from file system |
| Wired Pages | Pinned memory cache entries |
| Page Cache | File system cache (`.bin` files) |
| Swap Space | File system backing store |

This indirection decouples logical circuit references (zkid) from physical storage locations (checksum), enabling flexible caching strategies and content deduplication.

---

## Implementation Summary

### Core Components

✅ **Environment Extension** (`packages/vm/src/environment.rs`)

- `resolve_zkid_to_checksum(zkid: u64) -> Option<Checksum>` method
- Queries app state storage for zkid → checksum mapping
- Key format: `"zk_circuits:{zkid}"` → 32-byte Checksum

✅ **Host Import Function** (`packages/vm/src/imports.rs`)

- `do_proof_instance_verify` accepts `zkid: u64` parameter
- Resolves zkid to checksum, loads VK from VM cache
- Supports version 2 format with embedded constraint systems
- Returns 0 (valid) or 1 (invalid)

✅ **Cache Layer** (`packages/vm/src/cache.rs`)

- `store_code_with_circuit`: Validates and stores WASM + VK, pins VK by default
- `store_circuit`: Stores VK to file system cache and optionally pins
- `get_pinned_circuit`: Tiered lookup (pinned memory → file system)

### Architecture Design

The implementation uses a **two-level storage approach**:

1. **App State** (consensus-critical): Stores zkid → checksum mappings
2. **VM Cache** (performance optimization): Stores actual VK bytes with embedded CS

This design:

- ✅ Maintains consensus-critical data in app state
- ✅ Provides high-performance VK access through VM caching
- ✅ Supports circuit-agnostic verification via embedded constraint systems
- ✅ Enables zero-copy sharing of VKs via Arc pointers

### Integration Requirements

1. **Blockchain App Layer**:
   - Store `zk_circuits:{zkid}` → checksum mapping in consensus state
   - Call `store_code_with_circuit()` to store WASM and VK in VM cache
   - Implement zkid resolution in app state storage

2. **Contract Developers**:
   - Use `api.proof_instance_verify(zkid, proof, instances)`
   - Ensure zkid mappings are established before verification calls

3. **Node Operators** (optional performance tuning):
   - Monitor cache hit rates and memory usage
