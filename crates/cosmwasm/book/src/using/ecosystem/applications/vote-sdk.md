# Vote-Sdk

**vote-sdk** (Shielded Vote Chain) is a Cosmos SDK application for **private on-chain voting** using Zcash-derived cryptography: Halo2 ZKP circuits, RedPallas signatures, ElGamal encryption, and Poseidon Merkle trees.

| | |
|--|--|
| **Upstream project** | [valargroup/vote-sdk](https://github.com/valargroup/vote-sdk) — curated by the Valar / vote-sdk team |
| **Protocol draft** | [Shielded Voting Protocol ZIP](https://github.com/zcash/zips/pull/1200) |
| **Bridge into this VM** | `packages/zk-vote-bridge` in the CosmWasm fork (footer / VK packaging toward `proof_instance_verify`) |

For install, local chain, circuits, and FFI, **use the vote-sdk repository README and task runners**—this book does not duplicate their setup cookbook.

## What it provides (high level)

| Area | Contents |
|------|----------|
| Chain binary | Vote module, ceremony / rounds / tally keepers |
| Circuits | Halo2 + RedPallas (often via FFI into the app) |
| Crypto helpers | ECIES, ElGamal, Shamir, ZKP utilities |
| API / proto | REST and protobuf for clients |

Typical circuits named in the bridge crate include **delegation**, **vote commitment**, and **share reveal**.

## Connecting to ZK-CosmWasm

Halo2 crate versions may differ between vote-sdk and this fork. **Byte-level** serialization is the interoperability layer:

1. Export params + CS + VK bytes from vote-sdk keygen (per their docs).  
2. Wrap with a CosmWasm `CircuitFooter` (`zk-vote-bridge` / `VoteVerifyingKey`).  
3. Store the circuit on the CosmWasm host; assign a `zkid`.  
4. Contracts call `proof_instance_verify(zkid, proof, instances)` with matching public inputs.

Do not try to share Rust `VerifyingKey` types across incompatible halo2 versions.

## Integration checklist

- [ ] Decide whether verification runs on the **vote-sdk chain** (native FFI) or on a **CosmWasm host** via `proof_instance_verify`  
- [ ] Freeze circuit versions and footer metadata (`k`, `instances`, curve id)  
- [ ] Document public input order for each circuit  
- [ ] Register `zkid` mappings before mainnet contracts go live  

Participant / program framing lives under [Community](../../../community/overview.md); this page is for implementers only.
