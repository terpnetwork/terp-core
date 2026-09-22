# Storage And Caching

How the VM stores circuit material and serves hot verifying keys without re-deserializing on every tx.

Source: `ZK_STORAGE_AND_CACHING.md`.

## Why tiers exist

Commitment parameters are large and **shared** across circuits with the same `k`. Pinning a full params copy next to every VK wastes memory. The cache therefore:

- Stores **params** and **cs+vk** under separate content-addressed keys  
- Keeps a **monolithic** circuit blob for integrity and fallback  
- Serves **deserialized** VKs from pinned memory or a weight-bounded LRU  

## Cache hierarchy

| Tier | Key | Eviction | Persistence |
|------|-----|----------|-------------|
| Pinned memory | 72-byte circuit / 36-byte param | Manual pin/unpin only | Lost on process restart |
| In-memory LRU | Unified `CacheKey` (module / partial / circuit) | Weight-based LRU | Lost on restart |
| File system | Hex filenames under `zk_*` | Manual remove | Survives restart |

Unified LRU entries:

```rust
// Conceptual — see packages/vm cache module
enum CacheKey {
    Checksum(Checksum),   // Wasm modules
    PartialKey([u8; 36]), // param or vk body
    CircuitKey([u8; 72]), // full circuit
}
```

## On-disk layout

```
base_dir/state/wasm/
  <checksum>.wasm
  zk_param/<36-hex>.bin
  zk_vk/<36-hex>.bin
  zk_circuit/<72-hex>.bin
base_dir/cache/modules/<version>/<target>/<checksum>.module
```

Keys derive from the footer (`to_param_key`, `to_vk_key`, `to_circuit_key`).

## Lifecycle

### Store

```
serialized [params|cs|vk|footer]
  → check_circuit()  (dual SHA-256)
  → save_circuit_parts() → zk_param + zk_vk + zk_circuit
  → pin_circuit(circuit_key)  (typical default after store)
```

### Load

```
pinned hit  → CachedCircuit        (~µs)
LRU hit     → CachedCircuit
FS hit      → deserialize, promote to LRU
miss        → split param+vk load, or monolithic fallback
```

### Pin / unpin / remove

| Call | Effect |
|------|--------|
| `pin_circuit` | Ensure deserialized VK is in pinned map (idempotent) |
| `unpin_circuit` | Drop pinned entry (disk may remain) |
| `remove_circuit` | Unpin and delete circuit artifacts as implemented |

Exact semantics of unpin vs FS module removal are implementation-defined in the cache module; do not assume unpin alone deletes all three on-disk parts without checking current `packages/vm` behavior.

## Memory accounting

| Level | Use |
|-------|-----|
| Per-VK `size_estimate` | Weighting, metrics |
| Pinned / LRU totals | Observability, optional limits |
| Global pinned circuit memory | Optional host limits |

Pinned circuits are **not** automatically evicted. Treat pin as a performance wire for production hot paths.

## Operator tips

1. After restart, re-pin circuits that appear on every block.  
2. Watch pinned hit rate vs FS loads (deserialization is expensive).  
3. Prefer split layout so many circuits share param files for the same `k`.  
4. Keep consensus `zkid` mappings correct; cache cannot invent missing registry entries.

## Metrics (illustrative)

Hosts expose cache stats (hits on pinned/FS, misses, sizes). Use them when tuning memory limits for nodes that verify many distinct circuits.
