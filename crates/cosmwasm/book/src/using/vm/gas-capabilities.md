# Gas And Capabilities

How contracts declare what they need, and how the host meters ZK verification.

Sources: `docs/CAPABILITIES.md`, `docs/CAPABILITIES-BUILT-IN.md`, `docs/FEATURES.md`, `docs/GAS.md`, plus `GasConfig` in `packages/vm`.

## Capabilities (not Cargo features)

**Capabilities** negotiate functionality between a Wasm contract and the chain environment. They are **not** the same as Rust Cargo features (the old name “features” for this idea was retired; see `docs/FEATURES.md`).

### Contract side

Export a no-arg marker whose name starts with `requires_`:

```rust
#[cfg(feature = "iterator")]
#[no_mangle]
extern "C" fn requires_iterator() {}
```

If the host’s available capability set does not include every required marker, **store** fails early — better than discovering a missing host only at execute time.

Capabilities **signal availability**; they do not hard-block a contract from calling an import if the author ignores markers. Hosts still enforce import allow-lists and gas.

### Host side

`CacheOptions.available_capabilities` is set by the embedding chain (wasmvm / wasmd-style keepers), often from a CSV list.

### Built-in examples

| Capability | Rough meaning |
|------------|----------------|
| `iterator` | Range queries on storage |
| `staking` | Staking module messages/queries |
| `stargate` | Protobuf / IBC-era messages |
| `ibc2` | IBC v2 surfaces |
| `cosmwasm_1_1` … `cosmwasm_3_0` | Versioned query/message sets |

Chains may define additional capabilities. For ZK, enable the **`zk`** Cargo feature on `cosmwasm-std` for the import; ensure the linked wasmvm build implements `proof_instance_verify` and circuit queries. Treat ZK as a **host + std feature** concern; do not assume a universal `requires_zk` string without checking your chain’s capability list.

## Gas model (CosmWasm gas)

Upstream CosmWasm documents gas at [docs.cosmwasm.com — gas](https://docs.cosmwasm.com/core/architecture/gas). This fork keeps the same philosophy:

- Target order of magnitude: **~10¹² CosmWasm gas per second** of wall time on reference hardware (see comments in `GasConfig` and `docs/GAS.md`).  
- That maps to `GAS_PER_US = 1_000_000` — about **10⁶ gas per microsecond**.  
- Host crypto is charged via fixed costs or **`LinearGasCost`**: `base + n * per_item`.

SDK / Cosmos gas conversion is a **chain embedding** concern (wasmd / app multipliers). Contract authors and integrators should reason in **CosmWasm gas units** unless their chain docs say otherwise.

### Proof verification cost

`GasConfig::halo2_proof_instance_verify_cost` is a `LinearGasCost` charged inside `do_proof_instance_verify` (`packages/vm/src/imports.rs`).

**Size units** (not “number of proofs” alone):

```text
units = 1 + ceil(proof_bytes / 1024) + ceil(instance_bytes / 32)
cost  = base + units * per_item
```

**Default coefficients in tree** (subject to re-calibration; always verify against your release):

```text
base:     2_700 * GAS_PER_US   // ~2.7 ms fixed @ 10^6 gas/µs
per_item: 200 * GAS_PER_US     // ~200 µs per size unit
```

These defaults were set from host calibration (`verify_gas_calibrate` binary on the `zk-cosmwasm` package, BN254 path) with safety margin: measured square-circuit Groth16 p95 ≈ 2.0 ms → ~2.7 ms fixed at ~1.35× headroom; `per_item` scales with proof KiB and public-input limbs so large proofs cannot cheap-DoS the host. Re-run calibrate on **validator-class CPUs** after prover or layout changes.

Additionally (always charged for the call path):

- Generic **host call** cost  
- **Region read** costs for proof and instance buffers (`read_region_*`, size-dependent)

Invalid proofs that complete verification return `Ok(1)` **after** gas is charged for the work done. Missing circuits / parse failures return errors (gas already spent for work attempted).

### Other crypto hosts (context)

Default config also meters secp256k1, secp256r1, ed25519 (incl. batch), and BLS12-381 operations with the same µs × `GAS_PER_US` style. ZK verification is one more host path in that framework. For comparison, BLS12-381 pairing equality uses `per_item: 163 * GAS_PER_US` — that number is **not** the Halo2 proof default (older docs sometimes confused the two).

## Practical advice for developers

1. **Budget gas** for worst-case proof size and cold-path circuit load (first verify after restart may be heavier operationally even if gas is fixed by config).  
2. Prefer **pinned** circuits on validators that serve many ZK txs.  
3. Keep public inputs small and well-typed; oversized instance regions fail or waste gas.  
4. When targeting multiple chains, document required CosmWasm version capabilities **and** that the chain’s wasmvm must be ZK-enabled.  
5. After changing circuits or host crypto, re-run:

```bash
cargo run -p zk-cosmwasm --features bn254 --bin verify_gas_calibrate --release
```

## References in this repo

| Path | Content |
|------|---------|
| `docs/CAPABILITIES.md` | Negotiation model |
| `docs/CAPABILITIES-BUILT-IN.md` | Built-in list |
| `docs/GAS.md` | Points to upstream gas docs |
| `packages/vm/src/environment.rs` | `GasConfig` defaults |
| `packages/vm/src/imports.rs` | `do_proof_instance_verify` unit formula |
| `packages/zk/src/bin/verify_gas_calibrate.rs` | Calibration harness |
