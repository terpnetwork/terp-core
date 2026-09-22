# Specification: Evolving zk-cosmwasm into a Turing-Complete zkVM

**Version**: 1.0
**Date**: 2026-01-21
**Status**: Draft

---

## Executive Summary

Transform the current zk-cosmwasm programmable circuit verification VM into a true Turing-complete zkVM capable of proving arbitrary WASM smart contract execution, competitive with Cairo and Noir.

**Mission**: "Prove the prover validly proves proofs, permissionlessly" — extended to proving arbitrary WASM execution traces.

**Key Repos**:

- `crates/zk-wasmvm (mvp line)` - Go/Rust FFI layer with circuit caching
- `packages/ in this repo` - VM packages with proof verification infrastructure

**Design Decisions**:

- Circuit: K=18 (256K rows, ~4GB prover memory)
- Folding: `nova-snark` integration (~400 chunks for 10^6 steps)
- Memory: Page-based (64KB pages, WASM spec compliant)
- WASM subset: MVP (i32/i64, memory, tables, full control flow)
- **Execution Model**: Penumbra-inspired late binding (commit → batch → claim)
- **Batching**: Multi-user commitment batching
- **Output**: Selective disclosure (user chooses what to reveal)
- **Nesting**: Sub-commitments for nested contract calls

---

## References

### Primary Papers

1. **zk-WASM Paper**: "ZKWASM: A ZKSNARK WASM Emulator"
   - IEEE arnumber 10587123
   - Describes WASM ISA emulation in ZK circuits, execution trace proofs

2. **Hawk Paper**: "Hawk: The Blockchain Model of Cryptography and Privacy-Preserving Smart Contracts"
   - https://eprint.iacr.org/2015/675.pdf
   - Privacy-preserving smart contract execution model

3. **Nova/IVC**: "Nova: Recursive Zero-Knowledge Arguments from Folding Schemes"
   - https://eprint.iacr.org/2021/370
   - Incrementally Verifiable Computation via folding

4. **Halo2**: "Halo 2 and the Quest for Recursive Composition"
   - https://electriccoin.co/blog/halo-2/
   - PLONK-based proof system with no trusted setup

### Penumbra Protocol References

5. **Penumbra Protocol Specification**
   - https://protocol.penumbra.zone/main/
   - Overall architecture for private proof-of-stake

6. **Penumbra ZSwap (DEX)**
   - https://protocol.penumbra.zone/main/dex.html
   - Commit-batch-claim pattern for private swaps

7. **Penumbra Swap Action**
   - https://protocol.penumbra.zone/main/dex/action/swap.html
   - Swap commitment structure, encryption, nullifier derivation

8. **Penumbra SwapClaim Action**
   - https://protocol.penumbra.zone/main/dex/action/swap_claim.html
   - Merkle inclusion proofs, output note recovery

9. **Penumbra Flow Encryption**
   - https://protocol.penumbra.zone/main/crypto/flow.html
   - Homomorphic threshold encryption for aggregate computation

10. **Penumbra ZK Proofs Introduction**
    - https://www.penumbra.zone/blog/zkproofs-intro
    - https://www.redshiftzero.com/post/zkproofs-intro/
    - Groth16 on BLS12-377, transparent proof design

### zk-cosmwasm Existing Documentation

11. **ZK Circuit Quick Reference**
    - https://github.com/permissionlessweb/cosmwasm/blob/mvp/ZK_CIRCUIT_QUICK_REFERENCE.md

12. **ZK Circuit Serialization Format**
    - https://github.com/permissionlessweb/cosmwasm/blob/mvp/ZK_CIRCUIT_SERIALIZATION_FORMAT.md

13. **ZK Storage and Caching**
    - https://github.com/permissionlessweb/cosmwasm/blob/mvp/ZK_STORAGE_AND_CACHING.md

14. **ZK Proof Verification Architecture**
    - https://github.com/permissionlessweb/cosmwasm/blob/mvp/ZK_PROOF_VERIFICATION_ARCHITECTURE.md

15. **ZK CosmWasm Circuit Macro**
    - https://github.com/permissionlessweb/cosmwasm/blob/mvp/ZK_COSMWASM_CIRCUIT_MACRO.md

### Related Projects

16. **Delphinus zkWasm**
    - https://github.com/DelphinusLab/zkWasm
    - Reference WASM zkVM implementation

17. **nova-snark (Microsoft Research)**
    - https://github.com/microsoft/Nova
    - Rust implementation of Nova folding scheme

18. **Cairo (StarkWare)**
    - https://www.cairo-lang.org/
    - Competing zkVM using STARKs

19. **Noir (Aztec)**
    - https://noir-lang.org/
    - Competing zkDSL using Barretenberg

---

## Architecture Overview

### Current State

- **Programmable VM**: Upload VK circuits via `store_code_with_circuit()`, verify via `proof_instance_verify(zkid, proof, instances)`
- **Circuit Registry**: zkid → checksum mapping in app state
- **3-Tier Caching**: Pinned memory → File system → LRU
- **Serialization**: Version 2 format with 32-byte footer, embedded constraint system

### Target State

```
┌─────────────────────────────────────────────────────────────────┐
│                    zk-cosmwasm zkVM Architecture                │
├─────────────────────────────────────────────────────────────────┤
│  Layer 4: Smart Contracts                                       │
│  ├─ Call proof_instance_verify() for custom circuits      │
│  └─ Call wasm_execution_verify() for WASM execution proofs      │
├─────────────────────────────────────────────────────────────────┤
│  Layer 3: Host Imports (packages/vm/src/imports.rs)             │
│  ├─ do_proof_instance_verify() [existing]                 │
│  └─ do_wasm_execution_verify() [NEW]                            │
├─────────────────────────────────────────────────────────────────┤
│  Layer 2: Circuit Verification Engine                           │
│  ├─ Custom Circuits (user-uploaded VKs) [existing]              │
│  └─ WASM ISA Circuit (universal execution prover) [NEW]         │
├─────────────────────────────────────────────────────────────────┤
│  Layer 1: Execution Trace Capture (wasmtime instrumentation)    │
│  └─ Captures opcode, memory, stack traces for witness gen [NEW] │
└─────────────────────────────────────────────────────────────────┘
```

---

## Late Binding Execution Model (Penumbra-Inspired)

This design pushes computation to the edges using a commit-batch-claim pattern inspired by Penumbra's ZSwap architecture.

### Core Concept: Deferred Execution

Instead of proving execution synchronously, users:

1. **Commit** to execution intent (inputs only)
2. **Batch** with other users' commitments (chain aggregates)
3. **Claim** by proving execution off-chain, revealing selective outputs

```
┌─────────────────────────────────────────────────────────────────┐
│                    LATE BINDING EXECUTION FLOW                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  PHASE 1: EXECUTION_COMMIT (on-chain, fast)                     │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ User submits:                                            │    │
│  │   • bytecode_hash (which contract)                       │    │
│  │   • input_commitment = Poseidon(private_inputs)          │    │
│  │   • claim_address (encrypted to receiver)                │    │
│  │   • rseed (for deriving output note randomness)          │    │
│  │                                                          │    │
│  │ Chain stores:                                            │    │
│  │   • ecm = hash(bytecode_hash, input_cm, claim_addr)      │    │
│  │   • ecm added to Execution Commitment Tree               │    │
│  │   • Encrypted ciphertext stored for claim retrieval      │    │
│  └─────────────────────────────────────────────────────────┘    │
│                            ↓                                    │
│  PHASE 2: BATCH AGGREGATION (per block/epoch)                   │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ Chain aggregates multiple execution commitments:         │    │
│  │   • Group by bytecode_hash (same contract)              │    │
│  │   • Compute BatchExecutionData:                         │    │
│  │     - execution_count                                   │    │
│  │     - aggregated_input_commitment (if using flow enc)   │    │
│  │     - batch_merkle_root                                 │    │
│  │   • Store BatchExecutionData on-chain                   │    │
│  └─────────────────────────────────────────────────────────┘    │
│                            ↓                                    │
│  PHASE 3: EXECUTION_CLAIM (off-chain prove, on-chain verify)    │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ User generates proof off-chain:                          │    │
│  │   • Proves Merkle inclusion of ecm in commitment tree   │    │
│  │   • Proves execution: inputs → outputs (WASM ISA circuit)│    │
│  │   • Derives nullifier: nf = hash(nk, ecm, position)     │    │
│  │                                                          │    │
│  │ Chain verifies:                                          │    │
│  │   • Proof is valid                                       │    │
│  │   • Nullifier is unspent (prevents double-claim)         │    │
│  │   • Outputs consistent with claimed inputs               │    │
│  │                                                          │    │
│  │ User reveals (SELECTIVE DISCLOSURE):                     │    │
│  │   • Option A: Output commitment only (stays private)     │    │
│  │   • Option B: Specific outputs revealed publicly         │    │
│  │   • Option C: Mix of private commitments + public values │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Proto Types for Late Binding

```protobuf
// proto/headstash/zkvm/v1/late_binding.proto

// Phase 1: Commitment
message ExecutionCommit {
  bytes bytecode_hash = 1;           // 32 bytes - which contract
  bytes input_commitment = 2;        // 32 bytes - Poseidon(private_inputs)
  bytes claim_address = 3;           // encrypted claim destination
  bytes rseed = 4;                   // randomness for output derivation
  bytes encrypted_payload = 5;       // ExecutionCommitCiphertext
}

message ExecutionCommitment {
  bytes ecm = 1;                     // hash of ExecutionCommit fields
  uint64 position = 2;               // position in commitment tree
  uint64 block_height = 3;           // when committed
}

// Phase 2: Batch Data
message BatchExecutionData {
  bytes bytecode_hash = 1;
  uint64 execution_count = 2;
  bytes batch_merkle_root = 3;       // root of this batch's commitments
  uint64 epoch = 4;
}

// Phase 3: Claim
message ExecutionClaim {
  bytes nullifier = 1;               // prevents double-claim
  bytes anchor = 2;                  // merkle root at claim time
  bytes proof = 3;                   // ZK proof of execution
  repeated OutputNote outputs = 4;   // selective disclosure
  repeated SubCommitment nested = 5; // for nested contract calls
}

message OutputNote {
  oneof disclosure {
    bytes commitment = 1;            // private: just the commitment
    PublicOutput revealed = 2;       // public: actual value revealed
  }
}

message PublicOutput {
  bytes value = 1;
  bytes asset_id = 2;
  bytes recipient = 3;
}

// Nested execution support
message SubCommitment {
  bytes parent_ecm = 1;              // links to parent execution
  bytes sub_ecm = 2;                 // this sub-execution's commitment
  uint32 call_index = 3;             // order in parent's call sequence
}
```

### Nested Execution (Sub-Commitments)

When contract A calls contract B, the execution creates a tree of commitments:

```
ExecutionCommit (Contract A)
├─ SubCommitment[0]: Call to Contract B
│   ├─ SubCommitment[0.0]: Call to Contract C
│   └─ SubCommitment[0.1]: Call to Contract D
└─ SubCommitment[1]: Call to Contract E

All sub-commitments must be claimed before parent claim is valid.
Claim order: leaves → root (bottom-up)
```

**Circuit Constraint**: Parent claim proof includes:

- Hash of all child commitment nullifiers
- Proof that all children were validly claimed

### Benefits of Late Binding

1. **Computation at Edges**: Users prove execution on their hardware, chain only verifies
2. **Batching Efficiency**: Multiple executions share verification overhead
3. **Privacy by Default**: Inputs and outputs can remain committed
4. **Selective Disclosure**: User controls what becomes public
5. **Nested Composability**: Contract-to-contract calls supported via sub-commitments

---

## Phase 1: Execution Trace Infrastructure

### Objective

Instrument wasmtime to capture execution traces suitable for ZK witness generation.

### Tasks

**1.1 Define Proto Types** (`proto/headstash/zkvm/v1/`)

```protobuf
message ExecutionTrace {
  bytes bytecode_hash = 1;
  bytes initial_state_root = 2;
  bytes final_state_root = 3;
  uint64 step_count = 4;
  repeated InstructionStep steps = 5;
}

message InstructionStep {
  uint32 pc = 1;
  uint32 opcode = 2;
  repeated uint64 stack_before = 3;
  repeated uint64 stack_after = 4;
  repeated MemoryAccess memory_ops = 5;
}

message MemoryAccess {
  uint32 address = 1;
  bytes value = 2;
  bool is_write = 3;
}

message WasmExecutionInstance {
  bytes bytecode_hash = 1;      // 32 bytes
  bytes initial_state = 2;      // 32 bytes
  bytes final_state = 3;        // 32 bytes
  bytes input_hash = 4;         // 32 bytes
  bytes output_hash = 5;        // 32 bytes
}
```

**1.2 Wasmtime Instrumentation** (`zk-wasmvm/mvp/libwasmvm/`)

- Fork wasmtime's `Interpreter` to emit trace events
- Capture: PC, opcode, stack state, memory reads/writes
- Implement `TraceCollector` trait for witness streaming
- Add feature flag: `execution-tracing`

**1.3 Witness Generation Pipeline**

- `ExecutionTrace` → `WasmCircuitWitness` conversion
- Memory consistency sorting (for permutation argument)
- Stack transition validation

### Files to Modify

- `zk-wasmvm/mvp/libwasmvm/Cargo.toml` - add tracing feature
- `zk-wasmvm/mvp/libwasmvm/src/execution/` - new module for trace capture
- `proto/headstash/zkvm/v1/trace.proto` - new proto definitions

---

## Phase 2: WASM ISA Circuit (MVP Subset)

### Objective

Build Halo2 circuit proving correct WASM MVP execution.

### Target Instructions (i32/i64, memory, control flow)

```
Arithmetic: add, sub, mul, div_u, div_s, rem_u, rem_s, and, or, xor, shl, shr_u, shr_s
Memory: load, store (i32/i64 variants), memory.size, memory.grow
Control: block, loop, br, br_if, br_table, call, call_indirect, return
Stack: local.get, local.set, local.tee, global.get, global.set, drop, select
```

### Circuit Architecture

**2.1 Table-Based Design** (following zk-WASM paper)

```
┌────────────────────────────────────────────────────────────┐
│  Execution Table (main constraint)                         │
│  Columns: pc, opcode, stack_ptr, memory_ptr, ...          │
├────────────────────────────────────────────────────────────┤
│  Memory Table (sorted by address for consistency)          │
│  Columns: step, addr, value, is_write                      │
├────────────────────────────────────────────────────────────┤
│  Stack Table (LIFO consistency)                            │
│  Columns: step, stack_ptr, value                           │
├────────────────────────────────────────────────────────────┤
│  Jump Table (control flow targets)                         │
│  Columns: source_pc, target_pc, condition                  │
└────────────────────────────────────────────────────────────┘
```

**2.2 Chip Implementation** (`zk-cosmwasm/packages/zk-wasm/`)

- `ArithmeticChip` - i32/i64 operations (reuse foreign field patterns from secp256k1_chip)
- `MemoryChip` - Page-based (64KB) memory with merkle commitment per page
- `StackChip` - Stack depth tracking and LIFO enforcement
- `ControlFlowChip` - Branch validation, call frames
- `OpcodeDispatchChip` - Selector-based instruction routing

**2.3 Page-Based Memory Model**

```
Memory Layout (matches WASM linear memory spec):
┌─────────────────────────────────────────────────┐
│ Page 0 (64KB)  │ Page 1 (64KB)  │ ... │ Page N │
└─────────────────────────────────────────────────┘
              ↓
Page Commitment: Poseidon(page_data) → 32-byte hash
Memory Root: Merkle(page_commits[0..N]) → 32-byte root

Benefits:
- Sparse access efficient (only prove touched pages)
- Matches WASM memory.grow semantics
- State root = Merkle root of page commitments
```

**2.4 Public Instances**

```rust
pub struct WasmExecutionInstance {
    pub bytecode_hash: [u8; 32],
    pub initial_state_root: [u8; 32],
    pub final_state_root: [u8; 32],
    pub input_commitment: [u8; 32],
    pub output_commitment: [u8; 32],
    pub step_count: u64,
}
```

### Files to Create

- `zk-cosmwasm/packages/zk-wasm/` - new crate
- `zk-cosmwasm/packages/zk-wasm/src/circuit.rs` - main circuit
- `zk-cosmwasm/packages/zk-wasm/src/chips/` - instruction chips
- `zk-cosmwasm/packages/zk-wasm/src/tables/` - lookup tables

---

## Phase 3: Recursive Proof Aggregation (nova-snark integration)

### Objective

Enable proving 10^6+ step executions via chunked proving with folding.

### Design Decisions

- **Circuit Size**: K=18 (256K rows) → ~2.5K WASM steps per chunk
- **Prover Memory**: ~4GB (accessible hardware requirement)
- **Folding**: Integrate `nova-snark` crate (proven security, faster development)
- **Memory Model**: Page-based (64KB pages, matches WASM spec)

### Strategy: Nova-Style IVC with nova-snark

```
Chunk 1 (2.5K steps) → Proof₁ ─┐
Chunk 2 (2.5K steps) → Proof₂ ─┼─→ nova-snark Folded Accumulator → Final SNARK
Chunk 3 (2.5K steps) → Proof₃ ─┘
...
Chunk N (2.5K steps) → ProofN ─┘

For 10^6 steps: ~400 chunks folded into single proof
```

### Implementation

**3.1 Chunked Execution**

- Split execution trace into 2.5K-step chunks (fits K=18 circuit)
- Each chunk produces intermediate state commitment
- Chain chunks: `state_out[n] == state_in[n+1]`
- Page-based memory: track dirty pages per chunk

**3.2 nova-snark Integration**

- Add `nova-snark` dependency to `zk-cosmwasm/packages/zk-wasm/`
- Implement `StepCircuit` trait for WASM chunk circuit
- Use `RecursiveSNARK` for incremental verification
- Configure for Pallas/Vesta curve cycle (compatible with existing Halo2)

**3.3 Compression to Halo2**

- Final Halo2 PLONK proof wraps nova accumulator
- Single verification on-chain (~300-500K gas target)

### Files to Create

- `zk-cosmwasm/packages/zk-wasm/src/recursion/` - nova-snark wrapper
- `zk-cosmwasm/packages/zk-wasm/src/recursion/step_circuit.rs` - StepCircuit impl
- `zk-cosmwasm/packages/zk-wasm/src/recursion/compression.rs` - final SNARK

---

## Phase 4: VM Integration (Late Binding Actions)

### Objective

Integrate the late binding execution model into the CosmWasm VM with three new action types.

### 4.1 New Actions (Like Penumbra Swap/SwapClaim)

**Action 1: ExecutionCommit** (analogous to Penumbra's Swap)

```rust
// packages/std/src/actions/execution_commit.rs
pub struct ExecutionCommitAction {
    pub body: ExecutionCommitBody,
    pub proof: Vec<u8>,  // ZK proof of commitment integrity
}

pub struct ExecutionCommitBody {
    pub bytecode_hash: [u8; 32],
    pub input_commitment: [u8; 32],  // Poseidon(private_inputs)
    pub encrypted_payload: Vec<u8>,   // ExecutionCommitCiphertext
    pub claim_address: ClaimAddress,
}

// Proof demonstrates:
// - input_commitment is valid Poseidon hash
// - claim_address is well-formed
// - encrypted_payload encrypts to the commitment
```

**Action 2: ExecutionClaim** (analogous to Penumbra's SwapClaim)

```rust
// packages/std/src/actions/execution_claim.rs
pub struct ExecutionClaimAction {
    pub body: ExecutionClaimBody,
    pub proof: Vec<u8>,  // ZK proof of execution + Merkle inclusion
}

pub struct ExecutionClaimBody {
    pub nullifier: [u8; 32],         // Prevents double-claim
    pub anchor: [u8; 32],            // Merkle root at claim time
    pub outputs: Vec<OutputNote>,    // Selective disclosure
    pub nested_nullifiers: Vec<[u8; 32]>,  // For sub-commitments
}

// Proof demonstrates:
// - Valid Merkle path from ecm to anchor
// - Correct execution: inputs → outputs (WASM ISA circuit)
// - Nullifier correctly derived
// - All nested calls have valid nullifiers
```

**Action 3: BatchExecutionAggregate** (chain-initiated per block)

```rust
// packages/vm/src/batch.rs
pub struct BatchExecutionAggregate {
    pub bytecode_hash: [u8; 32],
    pub execution_count: u64,
    pub batch_root: [u8; 32],
    pub epoch: u64,
}
```

### 4.2 New Host Imports

**Location**: `zk-cosmwasm/packages/vm/src/imports.rs`

```rust
// Verify execution claim proof
pub fn do_execution_claim_verify<A, S, Q>(
    env: FunctionEnvMut<Environment<A, S, Q>>,
    anchor_ptr: u32,           // 32 bytes - Merkle root
    nullifier_ptr: u32,        // 32 bytes
    proof_ptr: u32,
    proof_len: u32,
    outputs_ptr: u32,          // serialized OutputNote[]
    outputs_len: u32,
) -> VmResult<u32>  // 0 = valid, 1 = invalid

// Check if nullifier is spent
pub fn do_nullifier_check<A, S, Q>(
    env: FunctionEnvMut<Environment<A, S, Q>>,
    nullifier_ptr: u32,        // 32 bytes
) -> VmResult<u32>  // 0 = unspent, 1 = spent

// Record nullifier as spent (called after valid claim)
pub fn do_nullifier_record<A, S, Q>(
    env: FunctionEnvMut<Environment<A, S, Q>>,
    nullifier_ptr: u32,        // 32 bytes
) -> VmResult<()>

// Query commitment tree anchor at height
pub fn do_get_anchor<A, S, Q>(
    env: FunctionEnvMut<Environment<A, S, Q>>,
    height: u64,
) -> VmResult<[u8; 32]>
```

### 4.3 State Trees

**Execution Commitment Tree** (append-only Merkle tree)

```
Storage: EXECUTION_COMMITMENTS: Map<position, ExecutionCommitment>
Root: Updated per block as new commitments added
Anchor History: Keep last N anchors for claim window
```

**Nullifier Set** (preventing double-claims)

```
Storage: NULLIFIERS: Map<[u8; 32], ()>
Check: O(1) lookup before accepting claim
Record: Insert after valid claim proof
```

### 4.4 Contract API Extension

**Location**: `zk-cosmwasm/packages/std/src/lib.rs`

```rust
impl Api {
    // Existing
    fn proof_instance_verify(&self, zkid: u64, proof: &[u8], instances: &[u8]) -> StdResult<u32>;

    // Late Binding Actions
    fn execution_commit(&self, commit: &ExecutionCommitBody) -> StdResult<ExecutionCommitment>;
    fn execution_claim(&self, claim: &ExecutionClaimBody, proof: &[u8]) -> StdResult<Vec<OutputNote>>;

    // Queries
    fn get_commitment_anchor(&self, height: Option<u64>) -> StdResult<[u8; 32]>;
    fn is_nullifier_spent(&self, nullifier: &[u8; 32]) -> StdResult<bool>;
}
```

### 4.5 Circuit Requirements

**ExecutionCommit Circuit** (lightweight, similar to Penumbra Swap)

- Proves: input_commitment = Poseidon(private_inputs)
- Proves: ecm = hash(bytecode_hash, input_cm, claim_addr, rseed)
- ~K=10 circuit (small, fast)

**ExecutionClaim Circuit** (main WASM ISA + Merkle)

- Proves: Merkle inclusion of ecm
- Proves: WASM execution trace (K=18, chunked with nova-snark)
- Proves: outputs derive from execution
- Proves: nullifier = hash(nk, ecm, position)

### Files to Create

- `zk-cosmwasm/packages/std/src/actions/execution_commit.rs`
- `zk-cosmwasm/packages/std/src/actions/execution_claim.rs`
- `zk-cosmwasm/packages/zk-wasm/src/circuits/commit_circuit.rs`
- `zk-cosmwasm/packages/zk-wasm/src/circuits/claim_circuit.rs`

### Files to Modify

- `zk-cosmwasm/packages/vm/src/imports.rs` - add new host imports
- `zk-cosmwasm/packages/std/src/traits.rs` - extend Api trait
- `zk-cosmwasm/packages/vm/src/cache.rs` - add commitment tree management
- `zk-wasmvm/mvp/libwasmvm/src/calls.rs` - FFI exports

---

## Phase 5: Testing & Verification

### Unit Tests

- Per-chip constraint validation with `MockProver`
- WASM spec test suite adaptation (arithmetic, memory, control flow)
- Property-based tests for witness generation

### Integration Tests

- End-to-end: WASM execution → trace → proof → verification
- Gas consumption benchmarks
- Cross-crate integration (zk-wasm ↔ cosmwasm-vm)

### Fuzz Testing

- WASM bytecode fuzzing
- Malformed trace detection
- Edge case discovery (stack overflow, memory bounds)

### Files to Create

- `zk-cosmwasm/packages/zk-wasm/src/tests/` - unit tests
- `zk-cosmwasm/packages/vm/src/integration_tests/wasm_execution.rs`
- `zk-wasmvm/mvp/tests/wasm_execution_test.go`

---

## Competitive Analysis

| Feature | Cairo | Noir | zk-cosmwasm (target) |
|---------|-------|------|----------------------|
| Proof System | STARK | Barretenberg | Halo2 PLONK |
| Verification Cost | ~1M gas | ~500K gas | <500K gas |
| Language | Cairo DSL | Noir DSL | **Any → WASM** |
| Trusted Setup | No | Yes | No (IPA) |
| Recursion | Yes | Yes | Yes (Nova) |
| Ecosystem | StarkNet | Aztec | **Cosmos/IBC** |

**Unique Advantages**:

1. **WASM universality** - prove Rust, Go, AssemblyScript contracts
2. **Cosmos native** - IBC-compatible cross-chain proofs
3. **Programmable** - custom circuits alongside universal WASM prover
4. **No trusted setup** - uses IPA commitment scheme
5. **Late binding** - Penumbra-inspired deferred execution pushes compute to edges
6. **Selective disclosure** - user-controlled privacy per output

### Comparison to Penumbra

| Aspect | Penumbra ZSwap | zk-cosmwasm zkVM |
|--------|----------------|------------------|
| Commit | Swap (trading pair, amounts) | ExecutionCommit (bytecode, inputs) |
| Batch | Per-block swap batching | Per-block execution batching |
| Claim | SwapClaim (mint outputs) | ExecutionClaim (reveal outputs) |
| Nullifier | Per-swap position | Per-commitment position |
| Privacy | Shielded amounts | Shielded inputs + selective output |
| Computation | AMM price calculation | Arbitrary WASM execution |

**Key Adaptation**: Penumbra commits to *swap intent* and claims *swap result*. We commit to *execution intent* (inputs only) and claim *execution result* (proved off-chain).

---

## Critical Files Summary

### New Files to Create

| Path | Purpose |
|------|---------|
| `proto/headstash/zkvm/v1/trace.proto` | Execution trace types |
| `proto/headstash/zkvm/v1/late_binding.proto` | Commit/Claim action types |
| `zk-cosmwasm/packages/zk-wasm/` | WASM ISA circuit crate |
| `zk-cosmwasm/packages/zk-wasm/src/circuit.rs` | Main WASM execution circuit |
| `zk-cosmwasm/packages/zk-wasm/src/chips/*.rs` | Instruction chips |
| `zk-cosmwasm/packages/zk-wasm/src/recursion/` | Nova-snark folding |
| `zk-cosmwasm/packages/zk-wasm/src/circuits/commit_circuit.rs` | ExecutionCommit proof |
| `zk-cosmwasm/packages/zk-wasm/src/circuits/claim_circuit.rs` | ExecutionClaim proof |
| `zk-cosmwasm/packages/std/src/actions/execution_commit.rs` | Commit action types |
| `zk-cosmwasm/packages/std/src/actions/execution_claim.rs` | Claim action types |
| `zk-wasmvm/mvp/libwasmvm/src/execution/trace.rs` | Trace capture |
| `zk-wasmvm/mvp/libwasmvm/src/commitment_tree.rs` | Merkle tree for commitments |

### Files to Modify

| Path | Changes |
|------|---------|
| `zk-cosmwasm/packages/vm/src/imports.rs` | Add late binding host imports |
| `zk-cosmwasm/packages/vm/src/cache.rs` | Add commitment tree, nullifier set |
| `zk-cosmwasm/packages/std/src/traits.rs` | Extend Api with commit/claim |
| `zk-cosmwasm/packages/std/src/query/wasm.rs` | Add anchor/nullifier queries |
| `zk-wasmvm/mvp/libwasmvm/src/calls.rs` | FFI exports |
| `zk-wasmvm/mvp/lib_libwasmvm.go` | Go bindings |

---

## Verification Plan

1. **Circuit Soundness**: Run `MockProver` on all test vectors
2. **Witness Correctness**: Compare trace output against wasmtime execution
3. **Gas Benchmarks**: Measure verification cost on testnet
4. **Security Audit**: External review of circuit constraints
5. **Spec Compliance**: WASM MVP test suite passing

---

## Design Decisions (Finalized)

### Circuit & Proving

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Circuit Size | K=18 (256K rows) | ~4GB prover memory, accessible hardware |
| Steps per Chunk | ~2.5K WASM ops | Fits K=18 with overhead for constraints |
| Folding Library | `nova-snark` | Proven security, Pallas/Vesta compatible |
| Memory Model | Page-based (64KB) | Matches WASM spec, efficient sparse access |
| Chunks for 10^6 steps | ~400 | Manageable folding depth |

### Late Binding Execution Model (Penumbra-Inspired)

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Commit Scope | Inputs only | Commit (bytecode_hash, input_commitment), proof generated at claim |
| Batching | Multi-user | Chain batches commitments per block/epoch |
| Output Disclosure | Selective | User chooses commitments vs revealed values |
| Nested Calls | Sub-commitments | Tree of commitments, claimed bottom-up |
| Nullifier Model | Per-commitment | hash(nk, ecm, position) prevents double-claim |
| Anchor Window | Configurable | Keep N recent roots for flexible claim timing |

## Dependencies to Add

```toml
# zk-cosmwasm/packages/zk-wasm/Cargo.toml
[dependencies]
nova-snark = "0.31"           # IVC folding
halo2_proofs = { ... }        # existing Halo2
pasta_curves = "0.5"          # Pallas/Vesta
ff = "0.13"                   # Field traits
```

---

## Appendix: Research Sources

### Papers Consulted

- **ZKWASM IEEE Paper** (arnumber 10587123) - WASM ISA circuit design
- **Hawk** (ePrint 2015/675) - Privacy-preserving smart contracts
- **Nova** (ePrint 2021/370) - Recursive proofs via folding
- **PLONK** (ePrint 2019/953) - Permutation-based polynomial IOP

### Protocol Documentation

- Penumbra Protocol Spec: https://protocol.penumbra.zone/main/
- Penumbra DEX (ZSwap): https://protocol.penumbra.zone/main/dex.html
- Penumbra Flow Encryption: https://protocol.penumbra.zone/main/crypto/flow.html

### Implementation References

- Delphinus zkWasm: https://github.com/DelphinusLab/zkWasm
- Microsoft Nova: https://github.com/microsoft/Nova
- halo2 book: https://zcash.github.io/halo2/

### Web Resources Used During Research

- https://www.penumbra.zone/blog/zkproofs-intro
- https://protocol.penumbra.zone/main/dex/action/swap.html
- https://protocol.penumbra.zone/main/dex/action/swap_claim.html
- https://zkv.xyz/what-is-penumbra-zone/
