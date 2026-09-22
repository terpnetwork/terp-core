# Design Survey

Survey of **light-client and tip-tracking designs** used or planned with this stack, emphasizing how they use **Zcash consensus and zero-knowledge primitives**, plus the **IBC / CosmWasm packaging** primitives that make them deployable. This is an ecosystem map, not a full protocol specification.

Upstream implementations and specs are **curated by their teams**—see links and [Light Clients](./light-clients.md#credits-and-upstream-sources).

## 1. Pure PoW Confirmation Depth

**Idea:** The consumer only accepts Zcash block headers (and related commitments) after enough **proof-of-work** accumulates.

| Aspect | Notes |
|--------|--------|
| Primitives | PoW headers, chain work, confirmation depth |
| Strength | Simple security story; no Crosslink validator set |
| Cost | Latency until depth is met |
| Examples / fixtures | PoW block fixtures under zebra-crosslink `crosslink-test-data/`; pure-PoW packaging may share modules with Crosslink clients |
| Book path | [Pure PoW Path](./pow.md) |

## 2. Crosslink Hybrid Finality

**Idea:** Track a **finality layer** that checkpoints or certifies progress while remaining anchored to Zcash work (parent PoW / hybrid model).

| Aspect | Notes |
|--------|--------|
| Primitives | Finality certificates + PoW parent linkage; often Ed25519 batch verify on roster signatures |
| Strength | Faster usable finality for apps |
| Cost | Additional assumptions on the finality set |
| Code | [ShieldedLabs/zebra-crosslink](https://github.com/ShieldedLabs/zebra-crosslink) · [cw-ics08-wasm-crosslink](https://github.com/cosmos/solidity-ibc-eureka/tree/main/programs/cw-ics08-wasm-crosslink) |
| Book path | [Crosslink Path](./crosslink.md) |

## 3. FlyClient-Style Succinct PoW (ZIP-221 Lineage)

**Idea:** Prove that a header is on a heavy chain with **sparse sampling** / succinct arguments rather than shipping the entire header history.

| Aspect | Notes |
|--------|--------|
| Primitives | PoW, Merkle/mountain-range style commitments, probabilistic proofs |
| Role here | Design space for **lighter ingress** and public verify demos |
| Honesty | Treat as **research / adjacent design**, not “only client you need” unless your deployment pins a specific implementation |

## 4. IBC 08-Wasm Light Client Programs

**Idea:** Encode client logic as **CosmWasm** bytecode stored via **ICS-08 wasm** so the consumer chain runs the LC in Wasm.

| Aspect | Notes |
|--------|--------|
| Spec / module | [ibc-go 08-wasm](https://github.com/cosmos/ibc-go/tree/main/modules/light-clients/08-wasm); CosmWasm host semantics from [CosmWasm](https://github.com/CosmWasm/cosmwasm) |
| Primitives | Whatever the Wasm client verifies (headers, sigs, membership proofs) |
| Strength | Upgradable client logic, same deployment story as contracts |
| Examples | Crosslink 08-wasm client; Eth 08-wasm peer in Eureka programs for packaging patterns |

## 5. IBC Classic Channels And IBC v2 / Eureka

**Idea:** Light clients are only half of interoperability—the **transport and packet model** (classic IBC channels vs IBC v2 / Eureka-style routing) shapes how apps consume verified state.

| Aspect | Notes |
|--------|--------|
| Primitives | Client state, consensus state, connection/channel (v1); v2 packet/client designs per Eureka docs |
| Code / docs | [cosmos/ibc](https://github.com/cosmos/ibc) specs · [solidity-ibc-eureka](https://github.com/cosmos/solidity-ibc-eureka) · monorepo notes (`docs/ibc-v2.md` where present) |
| Role here | Choose client **and** IBC version together; do not assume v1 packaging on a v2-only chain |

## 6. ZK Validity Over Batches (App + Host)

**Idea:** After a tip is trusted (or in parallel), applications submit **Halo2/PLONK proofs** verified by the **ZK-CosmWasm host** (`proof_instance_verify`), binding app state to public inputs.

| Aspect | Notes |
|--------|--------|
| Primitives | Halo2-class circuits, VK registry / `zkid`, public inputs |
| Strength | Selective disclosure and batch validity without putting full witnesses on-chain |
| Not a substitute for | Header / finality light clients—complements them |
| Book path | [Proof VM](../../vm/proof-vm.md), [Applications](../applications/applications.md) |

## 7. Privacy-Adjacent Membership Patterns

**Idea:** Orchard/note/nullifier **concepts** appear in **composition** (votes, auth, bounties identity), often as **circuits + app policy** rather than inside the header LC.

| Aspect | Notes |
|--------|--------|
| Primitives | Nullifiers, commitments, spend-auth style statements (as circuits allow) |
| Book path | [Vote-Sdk](../applications/vote-sdk.md), [Smart-Account Auth](../applications/smart-account-auth.md) |

## Choosing A Design

```
Need faster finality + accept hybrid set?  → Crosslink path
Need minimal assumptions, can wait?       → Pure PoW path  (see PoW chapter next to LC)
Need succinct historical PoW?             → FlyClient-style designs (evaluate maturity)
Need private/app validity proofs?         → VM proof host + applications
Need on-chain upgradable LC logic?        → 08-wasm packaging (ICS-08)
Need modern packet routing?               → Align IBC v1 vs v2 / Eureka with the client
```

## Expansion Beyond Zcash

Future **non-Zcash** light clients and app packs can sit beside these designs without rewriting the VM guide. Today’s survey is **Zcash-first**, with CosmWasm / IBC packaging as the shared deployment primitive.
