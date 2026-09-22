# Demo Map

Named surfaces for reproducing ZK-CosmWasm behavior as an external developer.

| Demo / artifact | Location | What it shows |
|-----------------|----------|---------------|
| VM proof path (unit / integration) | `packages/vm` tests (e.g. `proof_instance_verify_*`) | Cold path CircuitInfo → Circuit → verify; curve_id routing |
| Circuit cache benchmarks | `packages/vm/benches/`, criterion under `target/criterion/ZK*` | Pin/hot/warm load costs |
| Example Wasm contracts | `contracts/*` (esp. crypto-oriented samples) | Host crypto patterns; extend with `zk` where enabled |
| vote-sdk | [valargroup/vote-sdk](https://github.com/valargroup/vote-sdk) | Private voting stack (see upstream README) |
| zk-vote-bridge | `packages/zk-vote-bridge` | Footer-wrapped vote circuits for CosmWasm verify |
| Crosslink / PoW LC | [zebra-crosslink](https://github.com/ShieldedLabs/zebra-crosslink), [cw-ics08-wasm-crosslink](https://github.com/cosmos/solidity-ibc-eureka/tree/main/programs/cw-ics08-wasm-crosslink) | Hybrid finality + PoW header fixtures |
| Bounties e2e scripts | monorepo `crates/zec-bounties/scripts` | Auth handshake and public-mode ship path |

## Suggested learning order

1. Read [Proof VM overview](../../vm/proof-vm.md) and [Architecture](../../vm/architecture.md).  
2. Run or read a `proof_instance_verify` test in `packages/vm`.  
3. Serialize a toy circuit footer and store via VM cache APIs.  
4. Optionally run vote-sdk or light-client scripts if your product needs them.  

Hackathon submission themes: [Community hackathon](../../../community/hackathon.md).
