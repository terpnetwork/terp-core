# Circuits And Verifying Keys

How verifying keys are packaged for the CosmWasm VM, and how circuit developers produce compatible blobs.

Sources: `ZK_CIRCUIT_QUICK_REFERENCE.md`, `ZK_CIRCUIT_SERIALIZATION_FORMAT.md`, `ZK_COSMWASM_CIRCUIT_MACRO.md`.

## Goals

- **Circuit-agnostic verification**: host deserializes params + full constraint system + VK without the original Rust circuit type.
- **Param / VK separation**: commitment parameters (~60–70+ KiB for modest `k`) are shared across circuits with the same `k` and not duplicated per pinned entry when split storage is used.
- **Content addressing + integrity**: dual SHA-256 checksums in an 80-byte footer.

## Binary layout (monolithic)

```
[ Halo2 commitment params ]   param_len
[ Constraint system       ]   cs_len
[ Verifying key           ]   vk_len
[ CircuitFooter 80 bytes  ]
```

### Footer fields (80 bytes)

| Offset | Size | Field |
|--------|------|-------|
| 0 | 1 | `prover_id` (0 = Plonkish) |
| 1 | 1 | `curve_id` (e.g. Pasta; BN254 uses a distinct id) |
| 2 | 1 | `k` |
| 3 | 1 | `i` (public input scalar count) |
| 4–7 | 4 | `param_len` (u32 LE) |
| 8–11 | 4 | `cs_len` (u32 LE) |
| 12–15 | 4 | `vk_len` (u32 LE) |
| 16–47 | 32 | `param_checksum` = SHA256(params) |
| 48–79 | 32 | `vk_checksum` = SHA256(cs ‖ vk) |

`appstate_key` = `u32::from_be_bytes([prover_id, curve_id, k, 0])` — used when deriving file keys.

### Content-addressed keys

```
param_key   = appstate_key_le (4) ‖ param_checksum (32)   → 36 bytes
vk_key      = appstate_key_le (4) ‖ vk_checksum (32)      → 36 bytes
circuit_key = param_key ‖ vk_key                          → 72 bytes
```

Types live in `packages/zk` (`CircuitFooter`, `CwVerifyingKey`, `AnyVerifyingKey`, …).

## Split on-disk layout

Under the Wasm state base directory:

```
zk_param/<36-byte-hex>.bin      # params only
zk_vk/<36-byte-hex>.bin         # cs + vk (no footer)
zk_circuit/<72-byte-hex>.bin    # full blob including footer
```

Load prefers split files when both param and vk bodies exist; otherwise falls back to the monolithic circuit file. Every load re-checks both checksums.

## Contract-facing instances

- Encode public inputs as concatenated field elements (typically **32 bytes each**).
- Host builds `AnyInstance` from **`curve_id` in the footer**, so a single `zkid` space can hold circuits on different curves without remapping ids to curve enums.

Product mapping (Flock archives, Stwo lean, Groth16 JWT, vote-sdk, Pasta/Orchard-class): [Curve IDs And Terp Use Cases](./curve-use-cases.md).

## `#[cosmwasm_circuit]` macro (circuit authors)

The derive/attribute machinery under `packages/vm-derive` helps produce VM-compatible serialization:

- Analyzes `Circuit::configure()` for columns, gates, selectors, lookups, permutations  
- Emits footer metadata and `to_bytes_with_cs` / serialize-for-VM helpers  
- Compile-time checks for CS properties  

Typical attributes:

| Attribute | Meaning |
|-----------|---------|
| `k` | Circuit size (2^k rows); common range 11–20 |
| `instances` | Number of public input scalars |
| `footer_version` | ≥ 2 for CS-inclusive format |
| `analyze_cs` | Default true — full analysis |

Exact attribute surface may evolve; treat root `ZK_COSMWASM_CIRCUIT_MACRO.md` and the derive crate as SoT for macro details.

## Workflow checklist

1. Implement Halo2 (or supported) circuit; keygen VK with matching params.  
2. Serialize params, CS, VK; build footer with dual checksums (or use macro helpers).  
3. Store via `store_circuit` / `store_code_with_circuit` on the host.  
4. Register `zkid` → `circuit_key` in app state.  
5. From contracts, call `proof_instance_verify` with matching public inputs.  
6. Optionally pin hot circuits after restart for latency.

## Bridging external circuits

`packages/zk-vote-bridge` shows how **vote-sdk** Halo2 artifacts (possibly different crate versions) can be re-wrapped with a CosmWasm `CircuitFooter` so the VM’s `AnyVerifyingKey` path can verify them. Pattern: serialize bytes in the expected section order → attach footer → store → assign `zkid`.

## Quick doc map (repo root)

| Audience | Document |
|----------|----------|
| Circuit implementers | `ZK_COSMWASM_CIRCUIT_MACRO.md` |
| Byte format | `ZK_CIRCUIT_SERIALIZATION_FORMAT.md` |
| Index | `ZK_CIRCUIT_QUICK_REFERENCE.md` |
