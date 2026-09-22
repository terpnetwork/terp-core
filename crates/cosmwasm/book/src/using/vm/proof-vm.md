# Proof VM

ZK-CosmWasm extends CosmWasm so contracts can **verify zero-knowledge proofs on-chain** through a host import, with verifying keys (VKs) stored and cached like Wasm modules.

## What you get

| Concern | Stock CosmWasm | ZK-CosmWasm |
|---------|----------------|-------------|
| Crypto hosts | secp256k1, ed25519, BLS12-381, … | Same, **plus** Halo2/PLONK-style proof verification |
| Circuit selection | Smart-Contract Specific | Application-assigned **`zkid`** → circuit metadata / key |
| Storage of VKs | Smart-Contract Specific | Content-addressed blob (params + constraint system + VK + footer) |
| Contract API | `api.secp256k1_verify`, … | `api.proof_instance_verify(zkid, proof, instances)` (feature `zk`) |

Contracts do **not** re-implement proving systems in Wasm. They pass proof bytes and public inputs; the host resolves the circuit, loads the verifying key, and returns success/failure.

## Mental model

1. **Upload / register** a circuit verifying key (often with contract code via `store_code_with_circuit`, or as a standalone circuit via `store_circuit`).
2. **Map** an application `zkid` to the circuit’s content-addressed key (consensus/app state).
3. **Verify** from a contract:

```rust
// feature = "zk" on cosmwasm-std
let code = api.proof_instance_verify(zkid, &proof_bytes, &instance_bytes)?;
// 0 = valid proof, 1 = invalid proof
// Err = missing circuit, bad encoding, gas, or host error
```

Public **instances** are fixed-size field elements (length must be a multiple of 32 bytes per instance scalar encoding). Curve routing uses the circuit footer’s `curve_id`, not the numeric `zkid`.

## Host crypto surface

Contract Wasm imports under `env` (wired in `packages/vm`). **Highlighted rows** are entrypoints added in this fork (not stock CosmWasm). Feature flags must be enabled on the host build for those imports to exist.

<table class="api-surface">
  <thead>
    <tr>
      <th>Import / API</th>
      <th>Kind</th>
      <th>Feature</th>
      <th>Notes</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><code>secp256k1_verify</code></td>
      <td>Signature</td>
      <td>—</td>
      <td>ECDSA over secp256k1 (Cosmos default)</td>
    </tr>
    <tr>
      <td><code>secp256k1_recover_pubkey</code></td>
      <td>Signature</td>
      <td>—</td>
      <td>Pubkey recovery from compact signature</td>
    </tr>
    <tr>
      <td><code>secp256r1_verify</code></td>
      <td>Signature</td>
      <td>—</td>
      <td>ECDSA over P-256 (CosmWasm 2.1+)</td>
    </tr>
    <tr>
      <td><code>secp256r1_recover_pubkey</code></td>
      <td>Signature</td>
      <td>—</td>
      <td>P-256 recovery</td>
    </tr>
    <tr>
      <td><code>ed25519_verify</code></td>
      <td>Signature</td>
      <td>—</td>
      <td>EdDSA over ed25519</td>
    </tr>
    <tr>
      <td><code>ed25519_batch_verify</code></td>
      <td>Signature</td>
      <td>—</td>
      <td>Batch Ed25519 verify</td>
    </tr>
    <tr>
      <td><code>bls12_381_aggregate_g1</code></td>
      <td>Pairing curve</td>
      <td>—</td>
      <td>Aggregate G1 points (48-byte elements)</td>
    </tr>
    <tr>
      <td><code>bls12_381_aggregate_g2</code></td>
      <td>Pairing curve</td>
      <td>—</td>
      <td>Aggregate G2 points (96-byte elements)</td>
    </tr>
    <tr>
      <td><code>bls12_381_pairing_equality</code></td>
      <td>Pairing curve</td>
      <td>—</td>
      <td>Multi-pairing equality check</td>
    </tr>
    <tr>
      <td><code>bls12_381_hash_to_g1</code></td>
      <td>Hash-to-curve</td>
      <td>—</td>
      <td>Map message → G1 (<code>HashFunction</code> + DST)</td>
    </tr>
    <tr>
      <td><code>bls12_381_hash_to_g2</code></td>
      <td>Hash-to-curve</td>
      <td>—</td>
      <td>Map message → G2</td>
    </tr>
    <tr class="api-new">
      <td><code>proof_instance_verify</code> <span class="badge-new">NEW</span></td>
      <td>ZK proof</td>
      <td><code>zk</code></td>
      <td>Halo2 / Groth16 verify via <code>zkid</code> → circuit key</td>
    </tr>
    <tr class="api-new">
      <td><code>blake2b_256</code> <span class="badge-new">NEW</span></td>
      <td>Hash</td>
      <td><code>hash-blake</code></td>
      <td>BLAKE2b digest truncated/output 32 bytes</td>
    </tr>
    <tr class="api-new">
      <td><code>blake3_256</code> <span class="badge-new">NEW</span></td>
      <td>Hash</td>
      <td><code>hash-blake</code></td>
      <td>BLAKE3 256-bit digest</td>
    </tr>
    <tr class="api-new">
      <td><code>bn254_add</code> <span class="badge-new">NEW</span></td>
      <td>Pairing curve</td>
      <td><code>bn254</code></td>
      <td>EIP-196 ECADD on alt_bn128 G1</td>
    </tr>
    <tr class="api-new">
      <td><code>bn254_scalar_mul</code> <span class="badge-new">NEW</span></td>
      <td>Pairing curve</td>
      <td><code>bn254</code></td>
      <td>EIP-196 ECMUL on alt_bn128 G1</td>
    </tr>
    <tr class="api-new">
      <td><code>bn254_pairing_equality</code> <span class="badge-new">NEW</span></td>
      <td>Pairing curve</td>
      <td><code>bn254</code></td>
      <td>EIP-197 pairing check (also used by Groth16 path)</td>
    </tr>
  </tbody>
  <caption>
    Stock CosmWasm rows are always present on modern hosts. Rows marked
    <span class="badge-new">NEW</span> require the listed feature on the linked
    wasmvm / cosmwasm-vm build. Contract crates call
    <code>api.proof_instance_verify</code> via <code>cosmwasm-std</code> feature
    <code>zk</code>; hash and BN254 may be used as Wasm imports depending on std bindings.
  </caption>
</table>

### Hash functions

<table class="hash-ref api-surface">
  <thead>
    <tr>
      <th>Function</th>
      <th>Output</th>
      <th>Host import</th>
      <th>Status</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td>SHA-256 (BLS hash-to-curve mode)</td>
      <td>via <code>HashFunction</code></td>
      <td>inside <code>bls12_381_hash_to_g*</code></td>
      <td>Stock CosmWasm</td>
    </tr>
    <tr class="api-new">
      <td><code>blake2b_256</code> <span class="badge-new">NEW</span></td>
      <td>32 bytes</td>
      <td><code>env.blake2b_256</code></td>
      <td>feature <code>hash-blake</code></td>
    </tr>
    <tr class="api-new">
      <td><code>blake3_256</code> <span class="badge-new">NEW</span></td>
      <td>32 bytes</td>
      <td><code>env.blake3_256</code></td>
      <td>feature <code>hash-blake</code></td>
    </tr>
    <tr>
      <td><code>blake2b_512</code></td>
      <td>64 bytes</td>
      <td>—</td>
      <td>Library helper in <code>cosmwasm-crypto</code> only (not a host import)</td>
    </tr>
  </tbody>
  <caption>
    Poseidon / RedJubjub helpers may exist as library stubs; they are not listed
    until a stable host import is wired.
  </caption>
</table>

### Curves (signature &amp; pairing hosts)

Existing CosmWasm curve families used by the stock signature / BLS APIs:

<table class="curve-ref">
  <thead>
    <tr>
      <th>Curve / group</th>
      <th>APIs</th>
      <th>Typical use</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><strong>secp256k1</strong></td>
      <td><code>secp256k1_verify</code>, <code>secp256k1_recover_pubkey</code></td>
      <td>Tendermint / Cosmos account signatures</td>
    </tr>
    <tr>
      <td><strong>secp256r1</strong> (P-256)</td>
      <td><code>secp256r1_verify</code>, <code>secp256r1_recover_pubkey</code></td>
      <td>WebAuthn / passkey-style credentials</td>
    </tr>
    <tr>
      <td><strong>ed25519</strong></td>
      <td><code>ed25519_verify</code>, <code>ed25519_batch_verify</code></td>
      <td>Consensus / validator-style EdDSA; light-client batches</td>
    </tr>
    <tr>
      <td><strong>BLS12-381</strong> (G1 / G2)</td>
      <td><code>bls12_381_*</code></td>
      <td>Aggregate signatures, pairings, hash-to-curve</td>
    </tr>
  </tbody>
</table>

### Curves for proof verification (`curve_id`)

Footer field `curve_id` routes `proof_instance_verify` (independent of app `zkid`):

<table class="curve-ref api-surface">
  <thead>
    <tr>
      <th><code>curve_id</code></th>
      <th>Curve</th>
      <th>Circuit family</th>
      <th>Proving system</th>
    </tr>
  </thead>
  <tbody>
    <tr class="api-new">
      <td><code>0</code> <span class="badge-new">NEW</span></td>
      <td>Pasta (Vesta)</td>
      <td>Generic Plonkish</td>
      <td>Halo2</td>
    </tr>
    <tr class="api-new">
      <td><code>1</code> <span class="badge-new">NEW</span></td>
      <td>Pasta (Vesta)</td>
      <td>Vote delegation (ZKP #1)</td>
      <td>Halo2</td>
    </tr>
    <tr class="api-new">
      <td><code>2</code> <span class="badge-new">NEW</span></td>
      <td>Pasta (Vesta)</td>
      <td>Vote commitment (ZKP #2)</td>
      <td>Halo2</td>
    </tr>
    <tr class="api-new">
      <td><code>3</code> <span class="badge-new">NEW</span></td>
      <td>Pasta (Vesta)</td>
      <td>Share reveal (ZKP #3)</td>
      <td>Halo2</td>
    </tr>
    <tr class="api-new">
      <td><code>4</code> <span class="badge-new">NEW</span></td>
      <td>BN254 (alt_bn128)</td>
      <td>Generic Groth16 (snarkjs / circom)</td>
      <td>Groth16 (feature <code>bn254</code>)</td>
    </tr>
    <tr class="api-new">
      <td><code>5</code> <span class="badge-new">NEW</span></td>
      <td>M31</td>
      <td>Lean SSLE / fold / valset</td>
      <td>Stwo Circle STARK</td>
    </tr>
    <tr class="api-new">
      <td><code>6</code> <span class="badge-new">NEW</span></td>
      <td>BN256</td>
      <td>zkjwt.passkey</td>
      <td>Halo2 KZG / SHPLONK (feature <code>halo2-kzg</code>)</td>
    </tr>
    <tr class="api-new">
      <td><code>7</code> <span class="badge-new">NEW</span></td>
      <td>Flock (hash / GF(2))</td>
      <td>Hash-chain / archive attestation</td>
      <td>Flock Ligerito (`verify_ligerito`)</td>
    </tr>
  </tbody>
  <caption>
    Defined as <code>CurveType</code> in <code>packages/zk</code>. Host BN254
    precompiles (<code>bn254_*</code>) share the same curve family as id
    <code>4</code> but are separate entrypoints from proof verification.
    Terp product mapping: <a href="./curve-use-cases.md">Curve IDs And Terp Use Cases</a>.
  </caption>
</table>

## Stack layers

```
Contract (cosmwasm-std, feature "zk")
    → host import proof_instance_verify
        → resolve zkid → circuit_key (WasmQuery::CircuitInfo)
        → load VK (host cache / cold path Circuit query)
        → AnyVerifyingKey::verify(proof, instances)
```

Relevant crates in this repository:

| Crate | Role |
|-------|------|
| `packages/std` | Contract-facing API and Wasm imports |
| `packages/vm` | Host import, gas, cache integration |
| `packages/zk` | Footer, serialization, `AnyVerifyingKey` |
| `packages/zk-vote-bridge` | Example: vote-sdk circuits → CosmWasm footer format |
| `packages/crypto` | Shared crypto primitives used by the VM |

Go hosts typically consume this via a **wasmvm** build linked against the fork (e.g. monorepo `crates/zk-wasmvm`).


## Feature flags

- Enable **`zk`** on `cosmwasm-std` / contract crates that call `proof_instance_verify`.
- Host environments must wire circuit queries (`CircuitInfo` / `Circuit`) and the VM circuit cache loader.

See [Gas and capabilities](./gas-capabilities.md) for negotiation and metering.

## Next Chapters

- [Architecture](./architecture.md)  
- [Circuits And Verifying Keys](./circuits.md)  
- [Storage And Caching](./storage-caching.md)  
- [Gas And Capabilities](./gas-capabilities.md)  
- Ecosystem: [Light Clients](../ecosystem/light-clients/light-clients.md)  
