# Architecture

This chapter describes how multi-circuit proof verification works in the CosmWasm VM for integrators and contract authors.

Engineering source of truth: `ZK_PROOF_VERIFICATION_ARCHITECTURE.md`, `ZK_COSMWASM_ZKVM_SPEC.md` (repo root).

## Two-level identity

| Layer | Identifier | What it stores |
|-------|------------|----------------|
| **App / consensus** | `zkid` (u64 / u32 at the Wasm boundary) | Logical circuit id → content key / checksum mapping |
| **VM cache** | Circuit key (72 bytes) or component keys (36 bytes) | Actual serialized params, constraint system, VK |

Think of `zkid` as a virtual address and the circuit key as a physical page: contracts only ever pass `zkid`; operators and keepers manage content-addressed blobs.

Historically the mapping was described as `zk_circuits:{zkid}` → checksum. The host path used today resolves **`WasmQuery::CircuitInfo { zk_id }`** for metadata (including the 72-byte `circuit_key`), then loads bytes from the **host circuit cache** (Path A). On cache miss it falls back to **`WasmQuery::Circuit`** for the full blob (cold path).

## Host import

```text
do_proof_instance_verify(zkid, proof_ptr, proof_len, instances_ptr, instances_len) → u32
```

Implemented in `packages/vm/src/imports.rs`:

1. Charge host-call gas and read proof / instance regions from Wasm memory  
   - Proof max size: **2 MiB**  
   - Instances max size: **64 KiB**
2. Charge `halo2_proof_instance_verify` gas (linear cost model).
3. Query **CircuitInfo** for `zkid` → `circuit_key` (72 bytes).
4. Load verifying key:
   - Prefer host cache loader (no full circuit over the querier)
   - Else cold path: **Circuit** query → deserialize footer + body → `AnyVerifyingKey`
5. Decode instances with **`footer.curve_id`** (never with `zkid` as a curve hint).
6. Verify; return codes:
   - **`0`** — cryptographic verification succeeded  
   - **`1`** — proof does not verify (not a host crash)  
   - **`Err`** — missing registry entry, parse/format errors, gas, system query failure  

Contract sketch:

```rust
match api.proof_instance_verify(zkid, &proof, &instances) {
    Ok(0) => { /* accept */ }
    Ok(1) => { /* reject invalid proof */ }
    Ok(_) => { /* unexpected */ }
    Err(e) => { /* registry / encoding / gas */ }
}
```

## Upload path

| API (VM cache) | Purpose |
|----------------|---------|
| `store_code_with_circuit(code_bundle, checked, persist)` | Validate Wasm + VK; store both; pin VK by default; returns checksums |
| `store_circuit(vk_bytes, persist)` | Store / pin a circuit blob alone |

App layer responsibilities:

- Persist `zkid` → circuit key / metadata in consensus state  
- Ensure mappings exist **before** contracts verify against that `zkid`  
- Optionally re-pin hot circuits after node restart (disk survives; pinned memory does not)

## Virtual-memory analogy

| OS concept | ZK-CosmWasm |
|------------|-------------|
| Virtual address | `zkid` |
| Page table | App mapping / CircuitInfo |
| Physical frame | Deserialized VK in pinned memory |
| Page fault | Cache miss → disk or Circuit query |
| Wired pages | Pinned circuits |
| Page cache | File-system `.bin` under `zk_*` dirs |

## Roadmap note (zkVM)

`ZK_COSMWASM_ZKVM_SPEC.md` describes an evolution from **programmable circuit verification** (what ships today: upload VKs, verify proofs) toward a **Turing-complete WASM execution prover** (trace capture, late-binding commit/batch/claim, nested sub-commitments). That is design-forward material for protocol builders. **Day-to-day contract integration only needs the multi-circuit verify path above.**

## Error patterns operators see

| Symptom | Likely cause |
|---------|----------------|
| “circuit not found” / CircuitInfo error | `zkid` never registered or wrong chain state |
| Deserialization / footer errors | Corrupt blob, wrong format version, truncated file |
| `Ok(1)` | Valid host path, invalid proof or wrong public inputs |
| Instance length errors | Instances not multiple of 32-byte field elements |

## Implementation map

| Area | Path |
|------|------|
| Host import | `packages/vm/src/imports.rs` |
| Gas / env | `packages/vm/src/environment.rs` |
| Cache | `packages/vm/src/cache.rs`, `packages/vm/src/zk.rs` |
| Serialization | `packages/zk/` |
