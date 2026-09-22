# Source Document Map

Map engineering source-of-truth documents → reader chapters. Prefer the chapters for **how to build**; keep full specs in the linked sources when you need exhaustive detail.

## This Crate (`permissionlessweb/cosmwasm`)

| Repository path | Book chapter |
|-----------------|--------------|
| `README.md` | Introduction, [Proof VM](../vm/proof-vm.md) |
| `ZCASH_INTEGRATION.md` | [Proof VM](../vm/proof-vm.md) (context only; no TZE design dump) |
| `ZK_COSMWASM_ZKVM_SPEC.md` | [Architecture](../vm/architecture.md) |
| `ZK_PROOF_VERIFICATION_ARCHITECTURE.md` | [Architecture](../vm/architecture.md) |
| `ZK_CIRCUIT_QUICK_REFERENCE.md` | [Circuits And Verifying Keys](../vm/circuits.md) |
| `ZK_CIRCUIT_SERIALIZATION_FORMAT.md` | [Circuits And Verifying Keys](../vm/circuits.md) |
| `ZK_COSMWASM_CIRCUIT_MACRO.md` | [Circuits And Verifying Keys](../vm/circuits.md) |
| `ZK_STORAGE_AND_CACHING.md` | [Storage And Caching](../vm/storage-caching.md) |
| `docs/CAPABILITIES*.md`, `GAS.md`, `FEATURES.md` | [Gas And Capabilities](../vm/gas-capabilities.md) |
| `packages/vm/src/environment.rs` | [Gas And Capabilities](../vm/gas-capabilities.md) (`GasConfig`) |

## Tooling

| Path | Book chapter |
|------|--------------|
| `crates/cw-orchestrator/` (+ circuit macros) | [Cw-Orch Testing And Scripting](../tooling/cw-orch.md) |
| `crates/ict-rs/` (Docker spawn, QuickSpawnEnv, `terp` ZK suite) | [Cw-Orch Testing And Scripting](../tooling/cw-orch.md) |

## Ecosystem

| Path / repo | Book chapter |
|-------------|--------------|
| [zebra-crosslink](https://github.com/ShieldedLabs/zebra-crosslink), [cw-ics08-wasm-crosslink](https://github.com/cosmos/solidity-ibc-eureka/tree/main/programs/cw-ics08-wasm-crosslink) | [Light Clients](../ecosystem/light-clients/light-clients.md), [Crosslink](../ecosystem/light-clients/crosslink.md), [Pure PoW](../ecosystem/light-clients/pow.md) |
| [ibc-go 08-wasm](https://github.com/cosmos/ibc-go/tree/main/modules/light-clients/08-wasm), [solidity-ibc-eureka](https://github.com/cosmos/solidity-ibc-eureka) | [Design Survey](../ecosystem/light-clients/design-survey.md) |
| [valargroup/vote-sdk](https://github.com/valargroup/vote-sdk) | [Vote-Sdk](../ecosystem/applications/vote-sdk.md) |
| [terp-rs smart-accounts](https://github.com/permissionlessweb/terp-rs/tree/v0.0.2-dev/contracts/smart-accounts), Terp `x/smart-account` | [Smart-Account Authenticators](../ecosystem/applications/smart-account-auth.md) |
| `crates/zec-bounties/` | [Dao Bounties Embed](../ecosystem/applications/bounties-embed.md) |
