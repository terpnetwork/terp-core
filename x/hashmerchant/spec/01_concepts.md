<!--
order: 1
-->

# Concepts

## Merkle Reflection

Every blockchain maintains a **Merkle tree** — a cryptographic data structure that commits to the entirety of its state in a single hash called the **state root**. If you know the root, you can verify that any piece of data exists in the tree by checking a short **Merkle proof** (a path of sibling hashes from the leaf to the root).

**Merkle reflection** is the process of mirroring a foreign chain's state root onto Terp Network so that smart contracts can verify proofs against it locally. Instead of running a full light client for every chain you want to read from, the hashmerchant module lets validators collectively attest to the root during their normal consensus process.

The result: a CosmWasm contract on Terp can answer questions like _"Does address 0xABC hold 1000 USDC on Ethereum?"_ by checking a Merkle inclusion proof against a validator-attested Ethereum state root — without ever talking to Ethereum directly.

## Pallas Curve Re-hashing

Foreign chains use hash functions that are efficient in their own execution environments:

| Chain | Hash Algorithm | Merkle Structure |
|-------|---------------|-----------------|
| Ethereum | Keccak-256 | Modified Patricia Trie |
| Cosmos Hub | SHA-256 | IAVL+ Tree |
| Solana | SHA-256 | Account State Trie |

These hash functions are **not efficient inside ZK circuits**. To enable privacy-preserving proofs (e.g., proving token ownership without revealing your address), the hashmerchant system supports **re-hashing** foreign roots and proof paths into **Pallas-curve-compatible** representations.

The Pallas curve is the base curve of the Halo 2 proving system. By converting Merkle paths into Pallas-friendly hashes (Poseidon), we can:

- Build ZK proofs that attest to foreign-chain state
- Compose these proofs with other Pallas-based circuits
- Verify them on-chain at minimal gas cost

The re-hashing happens in the **validator sidecar** before attestation. The sidecar reads the native Merkle root, optionally computes its Pallas-compatible equivalent, and includes both in the vote extension. This way, the on-chain `HashRoot` can carry multiple `algo` variants (e.g., `keccak256` and `poseidon`) for the same foreign-chain height.

## Vote Extensions (ABCI++)

Traditional oracle designs use a separate submission/aggregation flow that runs outside of consensus. HashMerchant takes a fundamentally different approach: it embeds foreign-chain attestation **directly into CometBFT consensus** using ABCI++ vote extensions.

During each consensus round:

1. **ExtendVote**: CometBFT calls the application's `ExtendVote` handler. The validator's sidecar has pre-fetched the latest foreign-chain state root and injects it as a `VoteExtensionHashData` payload attached to the validator's vote.

2. **VerifyVoteExtension**: When a validator receives a peer's vote, CometBFT calls `VerifyVoteExtension`. The module checks that the attested chain is registered and enabled, rejecting malformed or unauthorized extensions.

3. **ProcessVoteExtensions**: At the start of the next block, the block proposer includes all vote extensions from the previous round. The module tallies them by `(chain_uid, algo, root)` weighted by each validator's voting power. If a root reaches quorum, it becomes a confirmed `HashRoot`.

This design means:

- **No separate oracle network** — the same validators securing the chain also attest to foreign state
- **Byzantine fault tolerant** — a root is only confirmed if 2/3+ of voting power agrees
- **Synchronous with consensus** — new roots are available every block, not on a delayed schedule
- **Free-riding resistant** — validators who don't run the sidecar simply submit empty extensions

## Quorum Verification

A foreign-chain root is only written on-chain when the **weighted voting power** of validators attesting to the same root exceeds the `quorum_fraction` parameter (default: 66.7%).

The quorum check operates per `(chain_uid, algo)` pair:

```
attesting_power = sum(voting_power of validators who reported the same root)
quorum_threshold = quorum_fraction * total_bonded_power

confirmed = attesting_power >= quorum_threshold
```

If multiple different roots are reported for the same `(chain_uid, algo)` in one round, only the root that reaches quorum (if any) is written. This prevents minority validators from injecting false state.

## Escrow-Gated Access

Smart contracts must **pay escrow** to receive hash root callbacks. This serves two purposes:

1. **Spam prevention** — without a cost gate, anyone could register unlimited contracts and consume block processing time via sudo callbacks
2. **Sustainability** — escrow fees fund the economic viability of the attestation market

The escrow flow:

1. A contract deployer calls `MsgRegisterContract` with an escrow deposit (minimum: 1 TERP in `uterp`)
2. The module transfers the escrow to the `hashmerchant` module account
3. The contract's `paid_until_height` is computed: `current_height + (deposit / min_escrow_amount) * prune_interval`
4. As long as the current block height is below `paid_until_height`, the contract receives sudo callbacks
5. When escrow expires, the contract is **automatically disabled** during the next prune cycle
6. The deployer can call `MsgRefillEscrow` at any time to extend the paid period

## Open vs Closed Market

The `market_mode` parameter controls who can provide attestations:

- **Open Market** (`MARKET_MODE_OPEN`): Any active validator may submit vote extensions with hash root data. This is the default and most decentralized mode.

- **Closed Market** (`MARKET_MODE_CLOSED`): Only governance-whitelisted validators may provide attestations. This mode is useful during early bootstrapping or for chains that require higher trust guarantees.

The market mode is changed via `MsgUpdateParams` (governance-gated).

## Sudo On-Ramp

When a `HashRoot` is confirmed (quorum reached), the module does not simply store it and wait for contracts to query it. Instead, it **actively pushes** the confirmed root to every registered contract via the CosmWasm `sudo` entrypoint.

This is the "on-ramp" — the point where validated foreign-chain data enters the smart contract execution environment:

```json
{
  "hash_merchant": {
    "chain_uid": "ethereum-mainnet",
    "algo": "keccak256",
    "height": 19500000,
    "root": "<32-byte state root>",
    "attestation_count": 85,
    "block_time": 1710000000
  }
}
```

The contract's `sudo` handler receives this message and can:

- **Store the root** for later proof verification
- **Trigger downstream logic** (e.g., update a price oracle, unlock a vault)
- **Emit events** for off-chain indexers

This push-based model means contracts always have the latest confirmed root without polling. The `sudo` entrypoint is privileged — only the chain itself (not users) can call it — making it a trusted data channel from the consensus layer to the smart contract layer.
