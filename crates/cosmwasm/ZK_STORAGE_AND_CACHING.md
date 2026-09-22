# Virtual Memory Cache Layer for Halo2 Circuit Keys in CosmWasm VM

---

## Introduction

This document describes the three-tier caching architecture used to store and retrieve Halo2 zero-knowledge proof circuit data. By extending the existing CosmWasm VM caching infrastructure with separate param/vk/circuit storage paths, we minimize memory pressure while keeping hot circuit keys instantly accessible.

The key insight: commitment parameters are 65KB+ and identical across all circuits sharing the same `k` value. Storing a copy of the params alongside every VK in pinned memory would waste hundreds of KB per circuit. Instead, params are stored independently and reconstructed only when the circuit is loaded from disk.

---

## Cache Architecture

### Cache Hierarchy Overview

| Layer | Key Type | Eviction Policy | Persistence |
|-------|----------|-----------------|-------------|
| **Pinned Memory** | `[u8; 72]` (circuit) / `[u8; 36]` (param) | Manual only | Until node restart |
| **In-Memory LRU** | `CacheKey` enum (unified) | LRU automatic | Until node restart |
| **File System** | `[u8; 72]` / `[u8; 36]` hex filenames | Manual only | Survives restart |

### CacheKey

The `InMemoryCache` uses a unified `CacheKey` enum to store modules, circuits, and params in a single LRU cache:

```rust
pub enum CacheKey {
    Checksum(Checksum),       // 32-byte WASM module checksum
    PartialKey([u8; 36]),     // 36-byte param or vk file key
    CircuitKey([u8; 72]),     // 72-byte compound circuit key
}
```

A single `WeightScale` implementation handles all three variants, using `size_estimate` for weight calculation.

---

## On-Disk Storage Layout

### Directory Structure

```
base_dir/
  state/
    wasm/
      <checksum>.wasm                    ← raw WASM bytecode
      zk_param/
        <36-byte-hex-key>.bin            ← params only (no footer)
      zk_vk/
        <36-byte-hex-key>.bin            ← cs + vk (no footer)
      zk_circuit/
        <72-byte-hex-key>.bin            ← params + cs + vk + 80-byte footer
  cache/
    modules/
      <version>/<target>/
        <checksum>.module                ← compiled wasmer module
```

### File Key Derivation

Each component is content-addressed using a key derived from the circuit footer:

```
param_key  = [4-byte appstate_key_le][32-byte param_checksum]  → 36 bytes → hex filename
vk_key     = [4-byte appstate_key_le][32-byte vk_checksum]     → 36 bytes → hex filename
circuit_key = [param_key][vk_key]                                → 72 bytes → hex filename
```

The `appstate_key` is a u32 combining `prover_id`, `curve_id`, `k`, and a zero byte (`u32::from_be_bytes([prover_id, curve_id, k, 0])`). This ensures circuits with different parameters cannot collide, even if they happen to share the same checksum.

Implementation: `CircuitFooter::to_param_key()`, `to_vk_key()`, `to_circuit_key()` in `packages/zk/src/footer.rs`.

---

## Data Structures

### CachedCircuit

```rust
pub struct CachedCircuit {
    pub vk: zk_cosmwasm::AnyVerifyingKey,  // fully deserialized VK with params
    pub size_estimate: usize,               // raw byte size of the serialized form
}
```

Holds a fully deserialized `AnyVerifyingKey` (params + vk + footer). This is what gets stored in all three cache tiers when a circuit is loaded.

### CachedParam

```rust
pub struct CachedParam {
    pub params: Vec<u8>,       // raw commitment-parameter bytes
    pub size_estimate: usize,
}
```

Holds only the raw param bytes — no deserialization, no VK. This is stored in the pinned and LRU caches so that param files don't need to be re-read from disk when loading a circuit that shares params with another circuit.

### CacheEntry (Unified LRU)

```rust
pub enum CacheEntry {
    Module(CachedModule),    // wasmer compiled module
    Circuit(CachedCircuit),  // deserialized VK + params
    Param(CachedParam),      // raw param bytes
}
```

All three variants share a single `CLruCache` with weight-based eviction, ensuring total memory never exceeds the configured `memory_cache_size_bytes`.

---

## Circuit Key Lifecycle

### Storage Flow

When a circuit is stored via `Cache::store_circuit(zk_bytes, persist)`:

```
[params][cs][vk][80-byte footer]
    │
    ▼
check_circuit()  ← validates both SHA256 checksums
    │
    ▼
parse footer
    │
    ▼
save_circuit_parts(param_dir, vk_dir, circuit_dir, zk_bytes, footer)
    │
    ├──→ zk_param/{param_key}.bin     = params only
    ├──→ zk_vk/{vk_key}.bin           = cs + vk (no footer)
    └──→ zk_circuit/{circuit_key}.bin = full blob (params + cs + vk + footer)
    │
    ▼
pin_circuit(circuit_key)
    │
    ├──→ FileSystemCache.load_circuit(circuit_key)   ← deserializes from disk
    └──→ PinnedMemoryCache.store_circuit(circuit_key, cached_circuit)
```

The free function `save_circuit_parts()` handles the actual file writes. The wrapper `save_circuit_to_disk()` delegates to it with all three directories set to the same path (for unit tests that use a flat temp dir).

### Retrieval Flow

When a circuit is loaded via `Cache::load_circuit(circuit_key)`:

```
load_circuit(circuit_key)
    │
    ├── PinnedMemoryCache hit?  → return CachedCircuit    ← <1 μs
    │
    ├── InMemoryCache hit?      → return CachedCircuit    ← <1 μs
    │
    ├── FileSystemCache hit?    → return, store in LRU    ← 1-10 ms
    │
    └── MISS: load_circuit_with_path(wasm_path, param_key, vk_key)
            │
            ├── zk_param/{param_key}.bin exists AND
            │   zk_vk/{vk_key}.bin exists?
            │   → read both files
            │   → validate checksums
            │   → AnyVerifyingKey::from_split_bytes(...)
            │   → store in FS cache + LRU cache
            │
            └── monolithic fallback:
                → zk_circuit/{circuit_key}.bin
                → load_circuit_from_disk()
                → AnyVerifyingKey::from_bytes()
```

### Pin and Unpin

`pin_circuit(circuit_key)`:

1. Check pinned cache — idempotent, skip if already pinned
2. Try `FileSystemCache.load_circuit()` — deserialized VK is ready
3. Fallback: `load_circuit_with_path()` → reconstruct from split files → serialize to FS cache → load back
4. Store in `PinnedMemoryCache`

`unpin_circuit(circuit_key)`:

1. Remove from `PinnedMemoryCache`
2. Remove from `FileSystemCache`
3. (LRU cache evicts naturally)

### Removal

`remove_circuit(circuit_key)`:
1. Remove from `FileSystemCache` (circuit module file)
2. Remove from `PinnedMemoryCache`
3. Remove circuit blob from disk under `zk_circuit/`

---

## Pinned Memory Cache

Provides the fastest access tier. Entries are never automatically evicted.

```rust
pub struct PinnedMemoryCache {
    modules: HashMap<Checksum, InstrumentedModule>,       // 32-byte key
    circuits: HashMap<[u8; 72], InstrumentedCircuit>,      // 72-byte circuit key
    params: HashMap<[u8; 36], InstrumentedParam>,          // 36-byte param key
}
```

### Core Operations

| Operation | Key Type | Description |
|-----------|----------|-------------|
| `store_circuit()` | `[u8; 72]` | Insert deserialized VK with hit count 0 |
| `load_circuit()` | `[u8; 72]` | Retrieve VK, increment hit counter |
| `has_circuit()` | `[u8; 72]` | Check existence without loading |
| `store_param()` | `[u8; 36]` | Insert raw param bytes |
| `load_param()` | `[u8; 36]` | Retrieve raw param bytes |
| `remove_circuit()` | `[u8; 72]` | Remove circuit entry |
| `remove_param()` | `[u8; 36]` | Remove param entry |

---

## In-Memory LRU Cache

Provides bounded, automatically-evicted storage for modules, circuits, and params. All three types share a single weight-bounded `CLruCache`:

```rust
impl WeightScale<CacheKey, CacheEntry> for SizeScale {
    fn weight(&self, key: &CacheKey, value: &CacheEntry) -> usize {
        let val_size = match value {
            CacheEntry::Module(m) => m.size_estimate,
            CacheEntry::Circuit(c) => c.size_estimate,
            CacheEntry::Param(p) => p.size_estimate,
        };
        std::mem::size_of_val(key) + val_size
    }
}
```

### Core Operations

| Operation | Key Type | Description |
|-----------|----------|-------------|
| `store()` | `Checksum` | Insert compiled wasmer module |
| `load()` | `Checksum` | Retrieve compiled module |
| `store_circuit()` | `[u8; 72]` | Insert deserialized VK |
| `load_circuit()` | `[u8; 72]` | Retrieve deserialized VK |
| `store_param()` | `[u8; 36]` | Insert raw param bytes |
| `load_param()` | `[u8; 36]` | Retrieve raw param bytes |
| `load_vk()` | `[u8; 36]` | Retrieve cs+vk body (partial key) |

---

## File System Cache

Provides persistent storage that survives node restarts. Circuit keys are stored as hex-encoded filenames with `.module` extension in the versioned modules directory.

```rust
impl FileSystemCache {
    fn circuit_file(&self, circuit_file_key: &[u8; 72]) -> PathBuf;
    fn param_file(&self, param_file_key: &[u8; 36]) -> PathBuf;

    pub fn load_circuit(&self, circuit_file_key: &[u8; 72]) -> VmResult<Option<CachedCircuit>>;
    pub fn store_circuit(&mut self, circuit_file_key: &[u8; 72], zk: &[u8]) -> VmResult<usize>;
    pub fn remove_circuit(&mut self, circuit_file_key: &[u8; 72]) -> VmResult<()>;
    pub fn remove_params(&mut self, param_file_key: &[u8; 36]) -> VmResult<()>;
}
```

Circuit files are stored as serialized blob bytes (params + cs + vk + footer). When loaded, the bytes are deserialized via `AnyVerifyingKey::try_from(bytes)` and the resulting `size_estimate` is the byte length of `to_bytes_with_params()`.

---

## Memory Management

### Size Tracking

The `PinnedMemoryCache::size()` method aggregates across both modules and circuits:

```rust
pub fn size(&self) -> usize {
    let module_size: usize = self.iter()
        .map(|(key, m)| std::mem::size_of_val(key) + m.module.size_estimate).sum();

    let circuit_size: usize = self.iter_circuits()
        .map(|(key, zk)| std::mem::size_of_val(key) + zk.circuit.size_estimate).sum();

    module_size + circuit_size
}
```

The `Stats` and `Metrics` structs provide visibility into cache behavior:

```rust
pub struct Stats {
    pub hits_pinned_memory_cache: u32,
    pub hits_memory_cache: u32,
    pub hits_fs_cache: u32,
    pub misses: u32,
}

pub struct Metrics {
    pub stats: Stats,
    pub elements_pinned_memory_cache: usize,
    pub elements_memory_cache: usize,
    pub size_pinned_memory_cache: usize,
    pub size_memory_cache: usize,
}
```

### PinnedMetrics

```rust
pub struct PinnedMetrics {
    pub per_module: Vec<(CacheKey, PerModuleMetrics)>,
}

pub struct PerModuleMetrics {
    pub hits: u32,
    pub size: usize,
}
```

The `CacheKey` variant in the metrics tuple indicates the entry type: `Checksum` for WASM modules, `CircuitKey` for circuits.

---

## Thread Safety

All cache operations are protected by a `Mutex<CacheInner>`:

```rust
pub struct Cache<A: BackendApi, S: Storage, Q: Querier> {
    available_capabilities: HashSet<String>,
    inner: Mutex<CacheInner>,
    instance_memory_limit: Size,
    instantiation_lock: Mutex<()>,
    wasm_limits: WasmLimits,
}
```

An additional `instantiation_lock` prevents concurrent access to `WasmerInstance::new`.

---

## Related Code Locations

| Component | Location |
|-----------|----------|
| `Cache` (main struct + store_code) | `packages/vm/src/cache.rs` |
| `Cache::store_circuit()` | `packages/vm/src/cache.rs:650` |
| `Cache::load_circuit()` | `packages/vm/src/cache.rs:786` |
| `Cache::pin_circuit()` | `packages/vm/src/cache.rs:725` |
| `Cache::remove_circuit()` | `packages/vm/src/cache.rs:694` |
| `save_circuit_parts()` (split writer) | `packages/vm/src/cache.rs:1173` |
| `load_circuit_with_path()` (split reader) | `packages/vm/src/cache.rs:890` |
| `PinnedMemoryCache` | `packages/vm/src/modules/pinned_memory_cache.rs` |
| `InMemoryCache` | `packages/vm/src/modules/in_memory_cache.rs` |
| `FileSystemCache` (circuit methods) | `packages/vm/src/modules/file_system_cache.rs` |
| `CachedCircuit`, `CachedParam`, `CacheEntry` | `packages/vm/src/modules/cached_module.rs` |
| `CacheKey` enum | `packages/vm/src/cache.rs:44` |
| `AnyVerifyingKey` | `packages/zk/src/circuits.rs` |
| `CircuitFooter` (key derivation) | `packages/zk/src/footer.rs` |