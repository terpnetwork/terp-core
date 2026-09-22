# Light Clients

**Light clients** in this stack are consumer-side programs (often **IBC 08-wasm** CosmWasm clients) that track **Zcash-related consensus and privacy-adjacent state** without running a full Zcash node on every appchain.

This chapter is **ecosystem-level**: which designs exist, how they use Zcash **zero-knowledge and consensus primitives**, and when to pick one. Implementation repos are maintained by their respective teams—we integrate and document; we do not claim authorship of those libraries.

## Credits And Upstream Sources

Libraries and specs below are **curated by their upstream teams**. Prefer their repositories for correctness, releases, and contribution norms.

| Project | Curated by / origin | Repository |
|---------|---------------------|------------|
| **ICS-08 Wasm light clients (IBC-Go)** | Cosmos / IBC-Go maintainers | [cosmos/ibc-go — 08-wasm](https://github.com/cosmos/ibc-go/tree/main/modules/light-clients/08-wasm) |
| **IBC light-client architecture** | IBC community | [IBC docs](https://ibc.cosmos.network/), [cosmos/ibc](https://github.com/cosmos/ibc) (specs including client semantics) |
| **IBC v2 / Eureka-oriented programs** | Cosmos Solidity IBC Eureka contributors | [cosmos/solidity-ibc-eureka](https://github.com/cosmos/solidity-ibc-eureka) |
| **cw-ics08-wasm-crosslink** | Eureka programs tree (+ monorepo packaging) | [programs/cw-ics08-wasm-crosslink](https://github.com/cosmos/solidity-ibc-eureka/tree/main/programs/cw-ics08-wasm-crosslink) |
| **cw-ics08-wasm-eth** (structural peer) | Same Eureka tree | [programs/cw-ics08-wasm-eth](https://github.com/cosmos/solidity-ibc-eureka/tree/main/programs/cw-ics08-wasm-eth) |
| **Zebra / Crosslink node stack** | Shielded Labs / Zebra lineage; permissionlessweb fork for integration | [ShieldedLabs/zebra-crosslink](https://github.com/ShieldedLabs/zebra-crosslink), [permissionlessweb/zebra-crosslink](https://github.com/permissionlessweb/zebra-crosslink) |
| **ics08-wasm client crates (Rust)** | IBC-rs maintainers / forks | [permissionlessweb/ibc-rs — ics08-wasm](https://github.com/permissionlessweb/ibc-rs/tree/main/ibc-clients/ics08-wasm) (upstream CosmWasm / IBC-rs ecosystem) |
| **Tendermint light client crates** | Informal / tendermint-rs maintainers | Tendermint-rs light-client packages in the monorepo vendor path |
| **CosmWasm contract & host model** | CosmWasm core teams | [CosmWasm/cosmwasm](https://github.com/CosmWasm/cosmwasm), [book.cosmwasm.com](https://book.cosmwasm.com/), [docs.cosmwasm.com](https://docs.cosmwasm.com/) |

Spec-oriented reading for integrators:

- [IBC light clients overview](https://ibc.cosmos.network/main/ibc/light-clients.html) (docs site may version-shift; follow current IBC-Go version).  
- ICS-08 Wasm module README and ADR notes in **ibc-go**.  
- IBC **v2** / multi-hop and Eureka design notes in **solidity-ibc-eureka** (`docs/`, program READMEs) and related monorepo notes such as Mercury `docs/ibc-v2.md` when present.

## What “Powered By Zcash ZK Primitives” Means

Zcash contributes more than “a hash chain.” Light-client designs in this ecosystem can draw on:

| Primitive family | Role for light clients |
|------------------|------------------------|
| **Proof-of-work headers** | Canonical chain work, confirmation depth, pure PoW clients — see [Pure PoW Path](./pow.md) |
| **Crosslink / hybrid finality** | Faster finality certificates layered on Zcash work — [Crosslink Path](./crosslink.md) |
| **ZIP-221 FlyClient-style ideas** | Succinct PoW header verification patterns for sparse sampling |
| **Halo2 / Orchard-class proving** | Validity proofs over batch state, selective disclosure, circuit VKs on the host |
| **Nullifiers / note commitments (conceptually)** | Privacy-preserving membership and spend-auth adjacent app protocols (via VM + composition, not always inside the LC Wasm) |

The **proof VM** verifies circuits on the consumer chain; **light clients** provide verification ability of *which Zcash (or hybrid) tip and roots* to trust. Together they enable “verify Zcash-grade crypto and headers in CosmWasm.”

## Design Families (Summary)

| Design | Trust model | ZK / crypto angle | Status (honest) |
|--------|-------------|-------------------|-----------------|
| **Crosslink path** | Hybrid finality over PoW | Finality + parent PoW; often paired with app-level Halo2 | Primary implemented LC path in monorepo |
| **Pure PoW path** | Confirmation depth only | Header work, no Crosslink committee — [details & fixtures](./pow.md) | Second trust dial; dual-path narrative |
| **FlyClient / sparse PoW** | Probabilistic PoW proofs | Succinct work proofs (ZIP-221 lineage) | Design / research adjacency for ingress |
| **08-wasm CosmWasm LC** | On-chain Wasm client | Host may verify signatures/proofs depending on client | Deployment shape for Crosslink (and peers) |
| **IBC v1 classic + IBC v2 / Eureka** | Channel / client models per IBC version | Same Wasm packaging; different wire and routing assumptions | Choose stack by consumer chain IBC version |
| **App-gated roots via proofs** | Application policy | `proof_instance_verify` on VM after LC tip advances | Composition pattern, not a separate LC binary |

Details: [Design Survey](./design-survey.md). Paths: [Crosslink Path](./crosslink.md), [Pure PoW Path](./pow.md), [Headers And Ingress](./ingress.md).

## Integrator Checklist

1. Choose a **trust dial** (pure PoW vs hybrid Crosslink vs future succinct PoW).  
2. Pin the **Wasm checksum** / store flow for the 08-wasm client.  
3. Define **ingress** (who feeds headers / certificates).  
4. Separate **header advancement** from **application ZK verification** (proof host).  
5. Align with **IBC v1 vs v2** capabilities on the consumer chain.  
6. Plan for **multi-source** ecosystems later—the LC section is Zcash-first, not Zcash-only forever.

## Next

- [Design Survey](./design-survey.md)  
- [Proof VM](../../vm/proof-vm.md) for on-chain circuit verify  
