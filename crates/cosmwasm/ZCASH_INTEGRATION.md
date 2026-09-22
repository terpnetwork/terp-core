# ZK-CosmWasm: Sovereign Appchains Settling to Zcash via TZE

**Category:** Consensus  
**Status:** Draft  
**Created:** 2026-01-16  
**License:** MIT  
**Dependencies:** ZIP-222, ZIP-244, ZIP-245

---

## Abstract

This proposal defines a Transparent Zcash Extension (TZE) type `L2_SETTLE` that enables sovereign L2 appchains running ZK-CosmWasm to settle state transitions to Zcash L1. The extension verifies bounded-size validity proofs (Halo2/PLONK) and BFT consensus certificates, allowing Zcash to serve as a settlement layer for privacy-preserving smart contract ecosystems without embedding a VM into the core protocol.

The design leverages ZIP-222's TZE framework to carry large proof witnesses outside of Bitcoin-style Script, while maintaining clean integration with Zcash's non-malleable transaction digests (ZIP-244/245).

---

## Motivation

### Why TZE?

Per ZIP-222, Transparent Zcash Extensions provide a mechanism for "complex forms of transparent output preconditions" without modifying Bitcoin Script interpretation. This is precisely what L2 settlement requires:

1. **Large Witnesses**: Validity proofs (Halo2: ~400 bytes, recursive STARKs: 50-100KB after compression) exceed Script size limits
2. **Typed Verification**: TZE's `(type, mode)` structure cleanly separates L2 verification from other consensus rules
3. **Non-Malleability**: ZIP-244/245 integration ensures proof witnesses don't affect transaction IDs
4. **Modular Activation**: New L2 types can be added via network upgrades without touching shielded protocols

### Why Not an Opcode?

As noted in the Starknet TZE discussion:

> "Zcash Script alone can't carry large ZK proofs. Transparent Script inherits Bitcoin-style resource limits (stack item and script size). Even if we chunked a proof, Script limits and lack of native covenants make feeding ~100 KB+ proofs via Script unrealistic."

TZE is the architecturally correct path for L2 settlement.

### Relationship to Starknet TZE Proposal

This proposal is complementary to the `STARK_VERIFY` TZE proposed by StarkWare. While that proposal focuses on Cairo VM execution proofs (Stone/Stwo verifiers), this proposal targets:

- **CosmWasm VM**: Rust-based smart contracts with existing Cosmos ecosystem tooling
- **Halo2 Proofs**: Leveraging Zcash's existing Orchard proof system (no new cryptographic assumptions)
- **BFT Consensus**: Malachite-based validator set with opt-in participation from Crosslink validators

Both proposals can coexist as separate TZE types, potentially sharing infrastructure for proof verification and fee pricing.

---

## Specification

### TZE Type Definition

```
TZE Type:       L2_SETTLE (type = <TBD>)
Modes:
  - Mode 0:     Halo2/PLONK validity proof + BFT certificate
  - Mode 1:     Recursive Halo2 proof (aggregated batches)
  - Mode 2:     (Reserved for future STARK integration)
```

### Precondition Structure

The `precondition` field encodes the L2 state commitment that must be satisfied:

```rust
struct L2SettlePrecondition {
    /// Unique identifier for the L2 chain (8 bytes)
    chain_id: [u8; 8],
    
    /// L2 block height being finalized
    height: u64,
    
    /// Previous state root (must match last settled state)
    prev_state_root: [u8; 32],
    
    /// New state root after block execution
    new_state_root: [u8; 32],
    
    /// Commitment to transaction batch (for DA verification)
    batch_commitment: [u8; 32],
    
    /// Verification key ID (references registered circuit)
    verifier_id: u16,
    
    /// Minimum validator stake threshold for this settlement
    min_stake_threshold: u64,
}
```

**Encoding**: All fields are serialized in little-endian order. Total precondition size: **130 bytes** (fixed).

### Witness Structure

The `witness` field contains the proof and consensus certificate:

```rust
struct L2SettleWitness {
    /// Halo2 validity proof (variable size, bounded)
    validity_proof: Vec<u8>,
    
    /// BFT consensus certificate
    bft_certificate: BftCertificate,
}

struct BftCertificate {
    /// Aggregated signature (BLS or Schnorr aggregate)
    aggregate_signature: [u8; 96],
    
    /// Bitmap of signing validators
    signer_bitmap: Vec<u8>,
    
    /// Total stake represented by signers
    total_stake: u64,
    
    /// Validator set commitment (Merkle root)
    validator_set_root: [u8; 32],
}
```

**Size Bounds** (consensus-enforced):

- `validity_proof`: ≤ 64 KiB (Mode 0), ≤ 128 KiB (Mode 1)
- `bft_certificate`: ≤ 4 KiB
- **Total witness**: ≤ 68 KiB (Mode 0), ≤ 132 KiB (Mode 1)

### Verification Algorithm

Per ZIP-222, the extension implements `tze_verify(mode, precondition, witness, context)`:

```rust
fn tze_verify(
    mode: u8,
    precondition: &L2SettlePrecondition,
    witness: &L2SettleWitness,
    context: &TzeContext,
) -> bool {
    // 1. Parse and validate precondition
    let chain_id = precondition.chain_id;
    let verifier_id = precondition.verifier_id;
    
    // 2. Load pinned verification key from L2 registry
    let vk = match context.get_l2_verifier_key(chain_id, verifier_id) {
        Some(vk) => vk,
        None => return false, // Unknown chain or verifier
    };
    
    // 3. Verify BFT certificate
    //    - Check 2/3+ stake signed
    //    - Verify aggregate signature over (height, new_state_root)
    //    - Verify signers are in registered validator set
    if !verify_bft_certificate(
        &witness.bft_certificate,
        precondition.height,
        &precondition.new_state_root,
        precondition.min_stake_threshold,
        context,
    ) {
        return false;
    }
    
    // 4. Verify validity proof
    //    - Public inputs: (prev_state_root, new_state_root, batch_commitment)
    //    - Proves: state transition is valid per L2 rules
    let public_inputs = [
        precondition.prev_state_root.as_slice(),
        precondition.new_state_root.as_slice(),
        precondition.batch_commitment.as_slice(),
    ].concat();
    
    match mode {
        0 => verify_halo2_proof(&vk, &public_inputs, &witness.validity_proof),
        1 => verify_recursive_halo2_proof(&vk, &public_inputs, &witness.validity_proof),
        _ => false,
    }
}
```

### L2 Registry

A new consensus-maintained registry maps `(chain_id, verifier_id)` to verification keys:

```rust
struct L2Registry {
    /// Map: chain_id -> L2ChainConfig
    chains: BTreeMap<[u8; 8], L2ChainConfig>,
}

struct L2ChainConfig {
    /// Human-readable name (for debugging/UI)
    name: String,
    
    /// Verification keys by verifier_id
    verifiers: BTreeMap<u16, VerificationKey>,
    
    /// Current validator set root
    validator_set_root: [u8; 32],
    
    /// Total staked amount for this L2
    total_stake: u64,
    
    /// Last settled state root
    last_state_root: [u8; 32],
    
    /// Last settled height
    last_height: u64,
    
    /// Registration block height
    registered_at: u32,
    
    /// Status: Active, Paused, Deprecated
    status: L2Status,
}
```

**Registry Updates**: New L2 chains and verification keys are registered via a separate TZE mode (`L2_REGISTER`, mode = 255) or governance mechanism.

### Consensus Rules

Per ZIP-222, the following rules apply:

1. **Outpoint Reference**: Each TZE input's `outpoint` MUST reference a prior `L2_SETTLE` precondition of the same type and mode.

2. **State Continuity**: The `prev_state_root` in the precondition MUST match the `new_state_root` from the referenced prior settlement (or the genesis root for the first settlement).

3. **Height Monotonicity**: The `height` MUST be exactly `prior_height + 1`.

4. **Stake Threshold**: The BFT certificate MUST represent ≥ 2/3 of the registered validator stake.

5. **Single Extension Type**: If a transaction has both TZE inputs and TZE outputs, all MUST have the same type (per ZIP-222 cross-extension attack prevention).

6. **Block Proportion Limit**: Per Daira's recommendation for STARK TZE, settlements SHOULD be limited to ≤ 1/4 of block capacity to prevent crowding out regular transactions.

### Fee Model

Following ZIP-317 logical actions model and the Starknet TZE discussion:

```
Settlement Fee = base_fee + (witness_bytes / 272) * marginal_fee
```

Where:

- `base_fee`: Equivalent to 2 logical actions (covers fixed verification cost)
- `marginal_fee`: Per-272-bytes rate (aligns with memo bundle pricing)
- 64 KiB witness ≈ 240 logical actions
- 128 KiB witness ≈ 480 logical actions

**Policy Limits** (non-consensus, mempool):

- At most 2 `L2_SETTLE` inputs per transaction
- At most 4 `L2_SETTLE` transactions per block (initially)

---

## L2 Architecture

### Validator Opt-in Market

Crosslink PoS validators can optionally participate in L2 consensus:

```
┌─────────────────────────────────────────────────────────────────┐
│                    CROSSLINK VALIDATORS                         │
│                                                                 │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐             │
│  │ Validator A │  │ Validator B │  │ Validator C │  ...        │
│  │ L1: ✓       │  │ L1: ✓       │  │ L1: ✓       │             │
│  │ L2: ✓ opt-in│  │ L2: ✗       │  │ L2: ✓ opt-in│             │
│  └──────┬──────┘  └─────────────┘  └──────┬──────┘             │
│         │                                  │                    │
│         └──────────────┬───────────────────┘                    │
│                        │                                        │
│                        ▼                                        │
│         ┌──────────────────────────────┐                       │
│         │  L2 VALIDATOR SET (subset)   │                       │
│         │  - Malachite BFT consensus   │                       │
│         │  - CosmWasm block production │                       │
│         │  - Proof generation          │                       │
│         └──────────────────────────────┘                       │
└─────────────────────────────────────────────────────────────────┘
```

**Registration Flow**:

1. Validator posts `L2_REGISTER` TZE transaction with:
   - L2 chain IDs they will validate
   - L2 public key for BFT signing
   - Stake delegation proof (links L1 stake to L2 participation)

2. Validator set updates are committed on-chain via periodic TZE transactions.

3. Slashing: Double-signing on L2 can result in stake slashing on L1 (requires Crosslink integration).

### L2 Block Flow

```
┌──────────────────────────────────────────────────────────────────┐
│                        L2 BLOCK PRODUCTION                       │
│                                                                  │
│  1. Proposer builds block                                        │
│     ┌─────────────────────────────────────────────────────────┐ │
│     │ CosmWasm Transactions                                    │ │
│     │ - Contract executions                                    │ │
│     │ - IBC packets                                           │ │
│     │ - ZK proof verifications                                │ │
│     └─────────────────────────────────────────────────────────┘ │
│                              │                                   │
│                              ▼                                   │
│  2. Malachite BFT consensus (AppMsg::GetValue → AppMsg::Decided) │
│     ┌─────────────────────────────────────────────────────────┐ │
│     │ Validators vote on block                                 │ │
│     │ 2/3+ stake required for finality                        │ │
│     │ Certificate generated with aggregate signature          │ │
│     └─────────────────────────────────────────────────────────┘ │
│                              │                                   │
│                              ▼                                   │
│  3. Prover generates validity proof                              │
│     ┌─────────────────────────────────────────────────────────┐ │
│     │ Halo2 circuit proves:                                    │ │
│     │ - All txns executed correctly                           │ │
│     │ - State transition prev_root → new_root is valid        │ │
│     │ - Batch commitment matches txn data                     │ │
│     └─────────────────────────────────────────────────────────┘ │
│                              │                                   │
│                              ▼                                   │
│  4. Settlement transaction posted to Zcash L1                    │
│     ┌─────────────────────────────────────────────────────────┐ │
│     │ TZE Output: L2_SETTLE precondition                      │ │
│     │ TZE Input:  L2_SETTLE witness (proof + certificate)     │ │
│     └─────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────┘
```

### Data Availability

Following the Starknet TZE discussion's observation:

> "Data availability (DA): out of scope for this TZE. DA can be a) fully on-chain (expensive), b) via commitment to an external DA layer, or c) hybrid."

This proposal uses **commitment-based DA**:

- `batch_commitment` in precondition commits to full transaction data
- Actual data stored off-chain (L2 nodes, dedicated DA layer like Celestia)
- Users can reconstruct L2 state from DA layer + L1 settlements

**Optional On-Chain DA**: For high-value settlements, batch data can be included in a memo bundle (ZIP-231) attached to the settlement transaction, up to 16 KiB per memo.

---

## L2 Contract Functions (CosmWasm)

These functions run on the L2 appchain, not Zcash L1:

### Cross-Chain Settlement

```rust
/// Verify Zcash L1 finality from L2 contract
pub fn verify_zcash_finality(
    deps: Deps,
    zcash_block_hash: [u8; 32],
    crosslink_certificate: CrosslinkCertificate,
    inclusion_proof: Halo2Proof,
) -> Result<FinalityAttestation, ContractError> {
    // Verify Crosslink BFT certificate
    // Verify inclusion proof against light client state
    // Return attestation for use in contract logic
}

/// Verify shielded ZEC deposit to L2
pub fn verify_shielded_deposit(
    deps: Deps,
    nullifier: [u8; 32],
    note_commitment: [u8; 32],
    merkle_proof: MerklePath,
    orchard_proof: Halo2Proof,
) -> Result<DepositAttestation, ContractError> {
    // Verify nullifier hasn't been seen
    // Verify note exists in Zcash commitment tree
    // Verify Orchard spend authorization
    // Mint wrapped ZEC on L2
}
```

### IBC Light Client

```rust
/// Update Zcash light client state on L2
pub fn update_zcash_client(
    deps: DepsMut,
    crosslink_header: CrosslinkHeader,
    validator_set_proof: Halo2Proof,
    finality_certificate: BftCertificate,
) -> Result<Response, ContractError> {
    // Verify header follows from previous
    // Verify validator set transition
    // Update consensus state for IBC
}

/// Verify IBC packet from Zcash or other chain
pub fn verify_ibc_packet(
    deps: Deps,
    client_id: String,
    height: Height,
    commitment_proof: MerkleProof,
    packet: Packet,
) -> Result<bool, ContractError> {
    // Standard ICS-23 Merkle proof verification
}
```

### ZK Verification Primitives

```rust
/// Verify arbitrary Halo2 proof against registered circuit
pub fn verify_halo2_proof(
    deps: Deps,
    circuit_id: u16,
    public_inputs: Vec<u8>,
    proof: Vec<u8>,
) -> Result<bool, ContractError> {
    // Load verification key from circuit registry
    // Verify proof against public inputs
}

/// Register new circuit verification key
pub fn register_circuit(
    deps: DepsMut,
    info: MessageInfo,
    circuit_id: u16,
    verification_key: Vec<u8>,
    circuit_metadata: CircuitMetadata,
) -> Result<Response, ContractError> {
    // Governance or admin authorization
    // Store verification key
    // Emit registration event
}
```

---

## Security Considerations

### Non-Malleability

Per ZIP-222:

> "It is the responsibility of `tze_verify` to enforce the following: `precondition` MUST be non-malleable: any malleation MUST cause `tze_verify` to return `false`."

The `L2_SETTLE` precondition uses fixed-size fields with deterministic encoding. The witness proof format is defined by Halo2's canonical serialization.

### Cross-Mode Attacks

Per ZIP-222's requirement to analyze cross-mode attack potential:

- **Mode 0 → Mode 1**: Different verification circuits; no shared state
- **Mode transitions**: Height monotonicity prevents replay across modes

### BFT Certificate Forgery

The BFT certificate requires:

- 2/3+ of registered stake
- Valid aggregate signature over `(height, new_state_root)`
- Signers must be in the current validator set Merkle tree

Forging a certificate requires compromising >1/3 of validator stake.

### Proof Size DoS

Per Daira's analysis in the Starknet TZE discussion:

> "The Zcash ecosystem would need to think very carefully about the implications of an >2 orders of magnitude increase over Sapling."

This proposal uses conservative bounds:

- 64 KiB (Mode 0) ≈ 85x Orchard proof size
- Block proportion limit of 1/4 prevents crowding

Future optimization via recursive proof composition (per Starknet discussion) could reduce proof sizes to 10-20 KiB.

### Validator Set Attacks

L2 validator sets are committed on-chain and require governance or stake-weighted voting to modify. Rapid validator set changes are rate-limited to prevent fast-rotation attacks.

---

## Rationale

### Why Not Embed VM in L1?

Per the Starknet discussion:

> "Wrt enshrining an alternative runtime in the L1: I don't think Cairo is a good fit and it wasn't designed for this."

And regarding shielded pool fragmentation:

> "I am concerned about fragmenting users' ZEC holdings in a different domain as the shielded pool on L1."

This proposal explicitly keeps VM execution off L1:

- Zcash L1 remains a clean settlement layer
- L2 handles programmability and scale
- ZEC bridges back to L1 for long-term shielded holding

### Why BFT + Validity Proof (Not Just Validity Proof)?

Pure validity proofs (ZK rollup style) would require:

- All L1 nodes to verify every L2 transaction
- Longer proof generation times (minutes to hours for large batches)

BFT consensus + validity proof provides:

- Fast finality on L2 (sub-second with Malachite)
- Batched settlement to L1 (amortizes proof generation)
- Fallback to BFT security if proof generation is slow

---

## Implementation

### Zcash L1 Changes

1. **TZE Host Path**: Implement `L2_SETTLE` type in `librustzcash/zcash_extensions`
2. **Halo2 Verifier**: Adapt existing Orchard verifier for L2 circuits
3. **L2 Registry**: Key-value store for chain configs and verification keys
4. **Fee Calculation**: Extend ZIP-317 for TZE logical actions
5. **RPC**: Methods to query L2 registry and settlement history

**Estimated LOC**: ~2,000 lines (excluding Halo2 verifier already present)

### L2 Implementation

1. **CosmWasm Runtime**: Standard CosmWasm with ZK verification module
2. **Malachite Integration**: BFT consensus with validator set from L1 registry
3. **Proof Generation**: Halo2 circuit for CosmWasm state transitions
4. **Settlement Relayer**: Posts settlement transactions to Zcash L1
5. **IBC Module**: Light client for Zcash and Cosmos chains

### Test Vectors

Will be provided in a companion document, including:

- Valid settlement transactions
- Invalid precondition/witness pairs
- BFT certificate verification cases
- Proof size boundary cases

---

## References

- [ZIP-222: Transparent Zcash Extensions](https://zips.z.cash/zip-0222)
- [ZIP-244: Transaction Non-Malleability Support](https://zips.z.cash/zip-0244)
- [ZIP-245: Transaction Identifier Digests & Signature Validation for TZE](https://zips.z.cash/zip-0245)
- [ZIP-317: Proportional Transfer Fee Mechanism](https://zips.z.cash/zip-0317)
- [ZIP-231: Memo Bundles](https://zips.z.cash/zip-0231)
- [Crosslink ZIP (Draft)](https://github.com/ShieldedLabs/crosslink_monolith)
- [Malachite BFT Consensus Engine](https://github.com/circlefin/malachite)
- [Halo2 Proving System](https://zcash.github.io/halo2/)
- [CosmWasm Documentation](https://docs.cosmwasm.com/)
- [Starknet TZE Forum Discussion](https://forum.zcashcommunity.com/)

---

## Acknowledgements

This proposal builds on:

- ZIP-222 design by Jack Grigg, Kris Nuttycombe, and contributors
- Starknet TZE proposal and forum discussion by Abdel and community
- Crosslink design by Shielded Labs
- Malachite consensus engine by Informal Systems / Circle
