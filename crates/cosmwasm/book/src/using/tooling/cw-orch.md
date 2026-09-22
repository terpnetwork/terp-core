# Cw-Orch Testing And Scripting

**cw-orch** (cw-orchestrator) is the typed Rust layer for **testing, scripting, and deploying** CosmWasm contracts. In this monorepo the fork under `crates/cw-orchestrator/` adds **first-class circuit artifacts** so the same workflow covers **ZK verifying keys** and **proof-host contracts**, not only Wasm.

Upstream docs: [orchestrator.abstract.money](https://orchestrator.abstract.money) · [docs.rs/cw-orch](https://docs.rs/cw-orch).  
Terp/ZK notes: `crates/cw-orchestrator/TERP_FORK.md`.

---

## What You Use It For

| Layer | Capability |
|-------|------------|
| **Contracts** | `#[interface(...)]` + `Uploadable` → upload / instantiate / execute / query on mock or chain |
| **Circuits (Terp fork)** | `circuit_interface` / `CircuitUploadable` → store VKs (`store-circuit` path), query by `zkid` |
| **Same code, many envs** | `Mock` → local daemon → Docker-spawned chain via **ict-rs** |
| **E2E suites** | Compose contract + circuit + optional sidecars (e.g. Nostr) under one test runtime |

---

## Circuit Compatibility (Terp Fork)

Stock cw-orch targets contracts. This fork extends the core so **circuits live next to contract artifacts** and share workspace helpers.

| Piece | Role |
|-------|------|
| `cw_orch_circuit_derive::circuit_interface` | Macro parallel to contract `interface` |
| `CircuitUploadable` | Trait for circuit binary paths (VK / zk blob) |
| `circuits_dir_from_workspace!` | Resolve `artifacts/` (or circuit subdirs) from workspace root |
| Artifact naming | `{name}_vk.bin` / `{name}_zk.bin` under `artifacts/` |
| Halo2 keys | **PK** = params + proving material; **VK** carries **terpvm circuit footer** metadata expected by zk-wasmvm |
| Daemon | `upload_circuit` / `upload_circuit_with_access_config` → chain `MsgStoreCircuit`-style flow; poll until `_circuit(zk_id)` succeeds |

```rust,ignore
use cw_orch::prelude::*;
// circuit_interface + CircuitUploadable from the Terp-extended prelude

// After upload: host can resolve zkid → VK; contracts call proof_instance_verify.
```

Builder flow:

1. Compile / export circuit VK (and optional zk package) into `artifacts/`.  
2. Implement `CircuitUploadable` (or generated `circuit_interface`) for that artifact name.  
3. On a chain env: **upload circuit** then **upload + instantiate** the verifier / app contract.  
4. Prove off-chain; submit proof + public inputs; assert host verify via contract execute/query.

See also: [Circuits And Verifying Keys](../vm/circuits.md), [Proof VM](../vm/proof-vm.md).

---

## Environments: Mock → Daemon → Docker (Ict-Rs)

```
  ┌─────────────┐     ┌──────────────────┐     ┌────────────────────────────┐
  │  Mock       │ →   │  Daemon          │ →   │  ict-rs QuickSpawn / Docker│
  │  multi-test │     │  live RPC/keys   │     │  real terpd + optional     │
  │  fast unit  │     │  local/testnet   │     │  sidecars (e.g. Nostr)     │
  └─────────────┘     └──────────────────┘     └────────────────────────────┘
         same cw-orch interfaces (TxHandler / QueryHandler / Environment)
```

### Mock

- `Mock::new(...)` for pure in-process multi-test.  
- Fast feedback for message shapes and basic execute paths.  
- Circuit host behavior depends on mock wiring; full zk-wasmvm host fidelity is for chain envs.

### Daemon (local or remote RPC)

```rust,ignore
let daemon = cw_orch::daemon::Daemon::builder()
    .chain(/* ChainInfo */)
    .build()?;
// contract + circuit uploads against a running node
```

### Ict-Rs: Live Containers, E2E Suites

**ict-rs** (`crates/ict-rs`) is the interchain / Docker test framework that **plugs into cw-orch**:

| API | Purpose |
|-----|---------|
| **QuickSpawn / SnapshotStore** | Snapshot a chain (genesis + keys), spawn a **Docker** `terpd` (or configured binary), wait for block 1, map ports |
| **`Daemon::builder().chain(spawned.to_chain_info())`** | Attach cw-orch daemon to the container RPC |
| **`QuickSpawnEnv`** | Wraps manager + daemon as `Environment<Daemon>` — drop-in for existing cw-orch tests; **Drop** stops the container |
| **`ict-rs-cw-orch`** | Crate glue between ict-rs and cw-orch |
| **`chain::terp` (feature `terp`)** | Traits for **Circuit + Contract + TerpVmSuite**: keygen/prove/verify lifecycle and on-chain **store-circuit** deploy against zk-wasmvm |
| **Sidecars** | e.g. Nostr relay in Docker for chain→event e2e |

```rust,ignore
// Conceptual e2e shape — see crates/ict-rs/ict-rs/README.md
let (spawned, _registry) = manager
    .spawn(&snapshot_id, &chain_config, "test-net")
    .await?;

let daemon = cw_orch::daemon::Daemon::builder()
    .chain(spawned.to_chain_info())
    .build()?;

// 1) upload_circuit via daemon / suite
// 2) upload + instantiate verifier contract
// 3) prove off-chain; execute verify path on-chain
// 4) manager.stop(&spawned).await?  (or QuickSpawnEnv drop)
```

**TerpVmSuite** (ict-rs `terp` feature) layers on cw-orch circuit types (`UploadableCircuit`, `CircuitPath`, `CwOrchCircuitUpload`, …) so a suite can:

- load/save proving & verifying keys  
- prove / verify off-chain  
- deploy VK on-chain (`store-circuit`)  
- bind an embedded Wasm verifier to that circuit  

Concrete demos (e.g. No Rick-style suites) implement those traits per circuit.

---

## Packages (Monorepo)

| Path | Role |
|------|------|
| `crates/cw-orchestrator/cw-orch` | Interfaces, prelude, **circuit_interface** re-export |
| `crates/cw-orchestrator/cw-orch-daemon` | Live chain + **upload_circuit** |
| `crates/cw-orchestrator/packages/cw-orch-core` | `circuits` module, `CircuitUploadable` |
| `crates/cw-orchestrator/packages/macros/cw-orch-circuit-derive` | Derive macros for circuits |
| `crates/ict-rs/ict-rs` | Docker spawn, QuickSpawnEnv, Terp ZK suite traits |
| `crates/ict-rs/ict-rs-cw-orch` | Adapter package |

---

## Recommended Test Ladder

1. **Unit** — mock cw-orch interfaces for contract messages.  
2. **Circuit artifacts** — generate VK/zk into `artifacts/`; unit-test serialize/footer if needed.  
3. **Integration** — daemon against local `terpd` with zk-wasmvm.  
4. **E2E** — ict-rs Docker spawn + upload circuit + contract + proof path; optional sidecars.  
5. **CI** — pin images/snapshots; always `stop` / Drop containers.

---

## See Also

- [Proof VM](../vm/proof-vm.md)  
- [Circuits And Verifying Keys](../vm/circuits.md)  
- [Applications](../ecosystem/applications/applications.md)  
- ict-rs README: `crates/ict-rs/ict-rs/README.md`  
- Fork notes: `crates/cw-orchestrator/TERP_FORK.md`  
