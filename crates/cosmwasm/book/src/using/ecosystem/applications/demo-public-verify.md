# Public Verify

How an external developer follows a **public verification** path: open clients, contracts, and reproducible checks—without private lab runbooks.

## Goals of a public verify path

1. **Anyone** can fetch client / contract artifacts (checksums, Wasm, circuit blobs).  
2. **Anyone** can re-run verification against published public inputs and proofs (or against chain state).  
3. **Operators** document RPC / LCD endpoints and light-client checksums in public channels.  

## Layers you can verify

| Layer | What to check | How |
|-------|---------------|-----|
| Circuit blob integrity | Dual SHA-256 in footer | `check_circuit` / load APIs; recompute checksums |
| On-chain proof | `proof_instance_verify` result | Submit or simulate tx calling the contract |
| Light client | Client not frozen; height advances | Query 08-wasm client state; compare to source tip |
| Vote ceremony (if used) | Published tallies / nullifiers | vote-sdk / app APIs and chain queries |
| Bounties public mode | DTO redaction | Call public list/detail; assert no private fields |

## Minimal contract-side pattern

```rust
// Pseudocode — wire to your ExecuteMsg
let code = deps.api.proof_instance_verify(zkid, proof, instances)?;
ensure!(code == 0, ContractError::InvalidProof {});
// then mutate state that is safe only after a valid proof
```

Ensure `zkid` is already registered on the target network; publish the circuit key / checksum next to your contract address in release notes.

## What not to rely on for “public”

- Private agent boards, lab SSH, or unpublished `.env` secrets  
- Unpinned “latest” Wasm without checksum  
- Proofs without public inputs and circuit id  

For program desk and forum links, see [Public surfaces](../../../community/public-surfaces.md).
