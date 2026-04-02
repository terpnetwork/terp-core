<!--
order: 6
-->

# Sudo Interface (Contract Traits)

When a hash root is confirmed, the module delivers it to registered CosmWasm contracts via the `sudo` entrypoint. This section defines the message schema (the "trait") and shows how to implement it in Rust.

## JSON Message Schema

Every sudo callback delivers a `HashMerchantSudoMsg` with the following structure:

```json
{
  "hash_merchant": {
    "chain_uid": "ethereum-mainnet",
    "algo": "keccak256",
    "height": 19500000,
    "root": "base64-encoded-32-byte-root",
    "attestation_count": 85,
    "block_time": 1710000000
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `chain_uid` | `string` | The registered chain identifier |
| `algo` | `string` | Hash algorithm used (e.g., `keccak256`, `sha256`, `poseidon`) |
| `height` | `uint64` | Block height on the foreign chain |
| `root` | `bytes` (base64) | The confirmed state root (32 bytes) |
| `attestation_count` | `uint32` | How many validators attested to this root |
| `block_time` | `int64` | Foreign chain block timestamp (unix seconds) |

## Rust Trait Definition

Contracts that want to receive hash root callbacks must implement the following sudo handler. This is the contract-side "trait" for the hashmerchant module:

```rust
use cosmwasm_std::{Binary, Uint64};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// The top-level sudo message dispatched by x/hashmerchant.
/// The contract's `sudo` entrypoint must handle this variant.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum HashMerchantSudoMsg {
    HashMerchant(HashMerchantPayload),
}

/// Payload carrying the confirmed foreign-chain state root.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, JsonSchema)]
pub struct HashMerchantPayload {
    /// Registered chain identifier (e.g. "ethereum-mainnet")
    pub chain_uid: String,
    /// Hash algorithm (e.g. "keccak256", "poseidon")
    pub algo: String,
    /// Foreign chain block height
    pub height: Uint64,
    /// The confirmed state root (32 bytes)
    pub root: Binary,
    /// Number of validators that attested
    pub attestation_count: u32,
    /// Foreign chain block timestamp (unix seconds)
    pub block_time: i64,
}
```

## Contract Implementation

A minimal contract that stores confirmed roots for later proof verification:

```rust
use cosmwasm_std::{
    entry_point, to_json_binary, Binary, Deps, DepsMut,
    Env, MessageInfo, Response, StdResult,
};
use cw_storage_plus::Map;

// Store confirmed roots: (chain_uid, algo) → HashMerchantPayload
const ROOTS: Map<(&str, &str), HashMerchantPayload> = Map::new("roots");

// Store root history: (chain_uid, algo, height) → root bytes
const ROOT_HISTORY: Map<(&str, &str, u64), Binary> = Map::new("root_hist");

/// The sudo entrypoint — called by the hashmerchant module, not by users.
#[entry_point]
pub fn sudo(deps: DepsMut, env: Env, msg: HashMerchantSudoMsg) -> StdResult<Response> {
    match msg {
        HashMerchantSudoMsg::HashMerchant(payload) => {
            // Store the latest confirmed root
            ROOTS.save(
                deps.storage,
                (&payload.chain_uid, &payload.algo),
                &payload,
            )?;

            // Optionally store in history for time-travel queries
            ROOT_HISTORY.save(
                deps.storage,
                (&payload.chain_uid, &payload.algo, payload.height.u64()),
                &payload.root,
            )?;

            Ok(Response::new()
                .add_attribute("action", "hash_merchant_root_received")
                .add_attribute("chain_uid", &payload.chain_uid)
                .add_attribute("algo", &payload.algo)
                .add_attribute("height", payload.height.to_string()))
        }
    }
}
```

## What Contracts Can Do With Confirmed Roots

Once a contract has a confirmed state root, it unlocks several powerful patterns:

### 1. Merkle Proof Verification

Users submit Merkle inclusion proofs off-chain. The contract verifies them against the confirmed root:

```rust
/// A user-submitted proof of foreign-chain state.
pub struct InclusionProof {
    /// The key in the foreign chain's state trie
    pub key: Binary,
    /// The value at that key
    pub value: Binary,
    /// Merkle proof path (sibling hashes from leaf to root)
    pub proof: Vec<Binary>,
    /// Which confirmed root to verify against
    pub chain_uid: String,
    pub algo: String,
}

// In execute handler:
fn verify_inclusion(deps: Deps, proof: InclusionProof) -> StdResult<bool> {
    let root = ROOTS.load(deps.storage, (&proof.chain_uid, &proof.algo))?;
    // Recompute root from proof path and compare
    let computed_root = compute_root_from_proof(&proof.key, &proof.value, &proof.proof);
    Ok(computed_root == root.root)
}
```

### 2. Cross-Chain State Reads

Prove specific facts about foreign-chain state:

- **Token ownership**: Prove an address holds tokens by verifying the balance storage slot
- **NFT ownership**: Prove ownership of an NFT by verifying the token-to-owner mapping
- **Contract state**: Read any contract's storage value with a Merkle proof
- **Account existence**: Prove an account exists on the foreign chain

### 3. ZK Proof Composition (Pallas Roots)

When the confirmed root uses the `poseidon` algo (Pallas-curve-compatible), contracts can:

- Accept ZK proofs generated off-chain using Halo 2 circuits
- Verify that a proof was computed against the correct state root
- Enable privacy-preserving cross-chain operations (prove membership without revealing identity)

### 4. Reactive Automation

Contracts can trigger automated actions when roots arrive:

- **Bridge settlement**: Release locked funds when foreign-chain deposits are confirmed
- **Oracle updates**: Update price feeds based on foreign DEX contract state
- **Governance sync**: Mirror voting results from a foreign DAO
- **Compliance monitoring**: Track token movements across chains

## Integration Checklist

To integrate a CosmWasm contract with the hashmerchant module:

1. Add the `HashMerchantSudoMsg` type to your contract
2. Implement the `sudo` entrypoint to handle `hash_merchant` messages
3. Deploy the contract to Terp Network
4. Register the contract: `terpd tx hashmerchant register-contract <addr> <chain_uid> <substores> <escrow>`
5. Maintain escrow balance to keep callbacks active
6. Implement execute handlers for users to submit Merkle proofs
