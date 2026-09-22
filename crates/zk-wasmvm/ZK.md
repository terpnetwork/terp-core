# Zk-WasmVM: Cosmwasm-VM paried with generic plonk verification key bindings

## TODO



```rs
// generic `VerifyingKey` struct/trait for zk-wasmvm:
// - ensures contracts implement `verify`

```

## Overview

## Specification

| Name     | Type       | Contains |   Description | Use Location |
|----------|-------------|--------------------------------------|--------------------------------------|------------|
| **CosmwasmCircuit** | Circuits define the private witnesses and compose the constraints to create the verifying and proving keys. This not needed during proof verification, only during proof or vk/pk generation. |  |  |  |
| **Params** |  Params define the values specific to a circuit, and contain the necessary data to define a circuit verifying key `vk`. Each halo2 circuit is similar, but dependent on the constant `K`, so when storing a circuits verifying key, we need specify the `K` value.  | `K`, `vk`  | | `zk-wasmvm` |
| **VerifyingKey** | Verifying keys are used for generating proofs for specific circuit instances. Each circuit hash its own set of keys, and in order to verify proofs, the vm layer must have access to the verification keys, along with the inputs required for proof verification (the proof bytes iteself and any public instances). |  | |  |
| **ProvingKey** |  Proving keys are used to generate proofs! These are stored client side, and are separate from proving keys. |    | |  |
| **Instance** |Instances are public inputs required to be provided along with a proof and a proving key in order to proove a statement.. under the hood we require instance values to be `pasta_curves::Fp`, so when storing a circuits verifying key, we need to specify how many instances a circuit expects, allowing us to generically verify circuits proofs within the vm.  Smart contracts can be programmed to define instances from the vm's environment such as block heights, light client headers, and other data from the chains application state, unlocking interesteing trust assumptions with zk-circuit design.  |  |  |  |
| **Proof** |  A proof is a value generated from a specific circuits proving keys, involving the private (witness) values. Proofs are a Vec<u8> of bytes. Our vm has a designated Proof definition to use as a generic wrapper for proofs in the vm. Specifically, we mirror default halo2 plonk proof functionality and define a proof that implements create and verify, so that we can pass in generic circuit and instance values and create a proof via plonk create proof  |  ||  |

### Storage

Like contracts, there is a dedicated storage layer for circuit keys in the vm. Keys can be stored with or without smart contracts. These keys are pinned to a dedicated caching layer by default, and governance can control the module parameters for who has permissions for uploading verifying keys.

### Serializing And Deserializing

We must define the canonical serialization and deserialization for circuits in order for us to have a fully programmable vm layer for proofs circuits, as we do with stateful applications via cosmwasm. Each circuit top two bytes is reserved and expected for cirucit builders to append to compiled plonk verifyingkeys. Specifically, we reserve the top two most bytes in the following order:

### BINARY FOOTER METADATA

Any compilation of circuit keys for zk-wasmvm must have appended 10 bytes to the file footer, as the vm expect these paramater bytes to be available for specifying specific parameters for each circuit.

| Byte     | Type       | Description|   Value | |
|----------|-------------|--------------------------------------|-------------------------------------|------------|
| `0` | `V` cosmwasm-vm version identifier |  |  |  |
| `1` | `I` # of public instances circuit requires to validate proof |  |  |  |
|    |  `vk_params.len()` | little-eidian byte length of vk-params    |  |  |
|   | `vk.len()`  | ittle-eidian  byte length of vk  |  |  |
|**TOTAL = 10 bits** |    |   |  |  |

- K: define the value set for plonk circuit verifying-key params
- Instances: define a number of public provided to a verifying key. We require smart contract developers to provide the array of `vesta::Scalar` values so that we have a canonical proof deserialization and request.

> note version bytes are assigned to compiled contract automatically, and we do not need to dedicate a byte for a circuits param constant `K`, as it is available as an object in a deserialized `VerifyingKey` `Params`.

### API

#### `MsgStoreCodeWithCircuit`

| Byte     | Type       | Description|   Value | |
|----------|-------------|--------------------------------------|--------------------------------------|------------|

### Cosmwasm Circuit Macro

The `#[cosmwasm_circuit]` derive macro simplifies creating circuits for the CosmWasm ZK-VM. This guide shows you how to use it.

## Zk-Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    HALO2 VERIFYING KEY LIFECYCLE                         │
│                   CosmWasm + Zero-Knowledge Integration                  │
└─────────────────────────────────────────────────────────────────────────┘

┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃ PHASE 1: BUILD & GENERATE (Off-chain, Developer Machine)              ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛

    ┌──────────────────┐
    │  Rust Circuit    │
    │  Definition      │
    │  (Halo2)         │
    └────────┬─────────┘
             │
             │ cargo build --release
             ▼
    ┌──────────────────┐         ┌──────────────────┐
    │  contract.wasm   │         │  build_and_write()│
    │  (CosmWasm)      │         │  (Proving Key)   │
    └────────┬─────────┘         └────────┬─────────┘
             │                            │
             │                            │ Generates
             │                            ▼
             │                   ┌──────────────────┐
             │                   │  vk_binary.bin   │
             │                   │                  │
             │                   │ [Params Bytes]   │
             │                   │ [VK Bytes]       │
             │                   └────────┬─────────┘
             │                            │
             └────────────┬───────────────┘
                          │
                          │ Developer prepares upload
                          ▼

┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃ PHASE 2: UPLOAD (On-chain Transaction via CLI/API)                    ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛

    $ wasmd tx wasm store-with-vk contract.wasm vk_binary.bin \
        --from deployer --gas auto
             │
             │ CLI Command
             ▼
    ┌──────────────────────────────────────────┐
    │  MsgStoreCodeWithCircuit                      │
    │  {                                       │
    │    wasm_byte_code: [...]                 │
    │    vk_byte_code: [Params][VK]           │
    │    instantiate_permission: {...}         │
    │  }                                       │
    └──────────────────┬───────────────────────┘
                       │
                       │ Blockchain Transaction
                       ▼
    ┌──────────────────────────────────────────┐
    │  Keeper: StoreCodeWithCircuit()               │
    │                                          │
    │  1. Validate WASM                        │
    │  2. check_vk(vk_byte_code)     │
    │  3. Compute checksums                    │
    │     - wasm_checksum = sha256(wasm)      │
    │     - vk_checksum = sha256(vk)          │
    │  4. Store on-chain metadata             │
    │  5. Emit CodeIDWithVK                   │
    └──────────────────┬───────────────────────┘
                       │
                       │ State Update
                       ▼
    ┌──────────────────────────────────────────┐
    │  Blockchain State                        │
    │                                          │
    │  CodeInfo {                              │
    │    code_id: 42                          │
    │    creator: "cosmos1..."                │
    │    wasm_checksum: 0xABCD...             │
    │    vk_checksum: 0x1234...               │
    │  }                                       │
    └──────────────────┬───────────────────────┘
                       │
                       │ Event: CodeStoredWithVK
                       ▼

┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃ PHASE 3: CACHE (Node Startup / First Use)                             ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛

    Node starts or first instantiate with code_id=42
             │
             │ Cache miss
             ▼
    ┌──────────────────────────────────────────┐
    │  FileSystemCache::save_wasm_with_vk()    │
    │                                          │
    │  Downloads from blockchain state         │
    └──────────────────┬───────────────────────┘
                       │
                       │ Write to disk
                       ▼
    ┌──────────────────────────────────────────┐
    │  Filesystem Cache                        │
    │  ~/.wasmd/cache/wasm/                    │
    │                                          │
    │  ├─ modules/                             │
    │  │  └─ v1-<checksum>.module              │
    │  │     (compiled WASM)                   │
    │  │                                       │
    │  └─ vks/                                 │
    │     └─ <checksum>.vk                     │
    │        [circuit_type: u8]                │
    │        [Params bytes]                    │
    │        [VK bytes]                        │
    └──────────────────┬───────────────────────┘
                       │
                       │ Persisted to disk
                       ▼

┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃ PHASE 4: PIN (Memory Optimization for Hot VKs)                        ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛

    Contract execution needs VK
             │
             │ High-frequency verification
             ▼
    ┌──────────────────────────────────────────┐
    │  Cache::pin_circuit(checksum)                 │
    │                                          │
    │  1. load_vk_from_disk()                  │
    │     ├─ Read file from cache              │
    │     ├─ Parse circuit_type (1 byte)       │
    │     └─ Extract VK bytes                  │
    │                                          │
    │  2. LoadedVerifyingKey::from_bytes()     │
    │     ├─ Deserialize Params                │
    │     │   let params = Params::read()      │
    │     └─ Deserialize VK (circuit-specific) │
    │         match circuit_type {             │
    │           Orchard => VK::read<Orchard>() │
    │           Other => VK::read<Other>()     │
    │         }                                │
    │                                          │
    │  3. Arc::new(loaded_vk)                  │
    │     Store in pinned_vk_cache             │
    └──────────────────┬───────────────────────┘
                       │
                       │ Pinned in RAM
                       ▼
    ┌──────────────────────────────────────────┐
    │  Memory Cache (LRU + Pinned)             │
    │                                          │
    │  pinned_vk_cache: HashMap {              │
    │    checksum_1 → Arc<LoadedVK> ──┐       │
    │    checksum_2 → Arc<LoadedVK>   │       │
    │  }                              │       │
    │                                 │       │
    │  ┌──────────────────────────────▼─────┐ │
    │  │  LoadedVerifyingKey              │ │
    │  │  {                                 │ │
    │  │    params: Params<vesta::Affine>  │ │
    │  │    vk: VerifyingKey<vesta::Affine>│ │
    │  │    original_size: usize            │ │
    │  │  }                                 │ │
    │  └────────────────────────────────────┘ │
    │                                          │
    │  Total pinned memory: 24.3 MB            │
    └──────────────────┬───────────────────────┘
                       │
                       │ Ready for instant access
                       ▼

┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃ PHASE 5: VERIFY (Contract Execution with ZK Proof)                    ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛

    User calls: verify_proof(proof_bytes)
             │
             │ Contract execution
             ▼
    ┌──────────────────────────────────────────┐
    │  WASM Contract (Rust)                    │
    │                                          │
    │  #[entry_point]                          │
    │  pub fn execute(                         │
    │    deps: DepsMut,                        │
    │    env: Env,                             │
    │    msg: ExecuteMsg                       │
    │  ) -> Result<Response> {                 │
    │    match msg {                           │
    │      Verify { proof } => {               │
    │        deps.api.verify_halo2_proof(      │
    │          &proof,                         │
    │          &public_inputs                  │
    │        )?;                               │
    │      }                                   │
    │    }                                     │
    │  }                                       │
    └──────────────────┬───────────────────────┘
                       │
                       │ Host function call
                       ▼
    ┌──────────────────────────────────────────┐
    │  wasmvm: do_verify_halo2_proof()         │
    │                                          │
    │  1. Get cached LoadedVK (from pinned)    │
    │     let vk = cache.get_pinned_vk()      │
    │                                          │
    │  2. Deserialize proof bytes              │
    │     let proof = Proof::read(proof_bytes) │
    │                                          │
    │  3. Parse public inputs                  │
    │     let public_inputs = [...];          │
    │                                          │
    │  4. Create verifier strategy             │
    │     let strategy = SingleStrategy::new(  │
    │       &vk.params                         │
    │     );                                   │
    │                                          │
    │  5. VERIFY THE PROOF                     │
    │     verify_proof(                        │
    │       &vk.params,                        │
    │       &vk.vk,                            │
    │       strategy,                          │
    │       &[&[&public_inputs]],             │
    │       &mut transcript                    │
    │     )?;                                  │
    │                                          │
    │  ✓ Proof is valid                        │
    └──────────────────┬───────────────────────┘
                       │
                       │ Return success
                       ▼
    ┌──────────────────────────────────────────┐
    │  Contract Response                       │
    │                                          │
    │  Response::new()                         │
    │    .add_attribute("action", "verify")    │
    │    .add_attribute("status", "success")   │
    └──────────────────┬───────────────────────┘
                       │
                       │ Transaction success
                       ▼
    ┌──────────────────────────────────────────┐
    │  Blockchain State Updated                │
    │                                          │
    │  ✓ Zero-knowledge proof verified         │
    │  ✓ Privacy preserved                     │
    │  ✓ Computation validated                 │
    └──────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│  KEY INNOVATIONS                                                         │
│  • Upload once, verify everywhere (blockchain distribution)              │
│  • Memory-efficient caching with LRU + pinning                          │
│  • Circuit-type aware deserialization                                    │
│  • Zero-knowledge proofs in CosmWasm smart contracts                    │
│  • Gas-metered cryptographic verification                                │
└─────────────────────────────────────────────────────────────────────────┘
```
