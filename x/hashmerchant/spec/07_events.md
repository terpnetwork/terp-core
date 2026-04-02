<!--
order: 7
-->

# Events

The `x/hashmerchant` module emits the following events:

## hashmerchant_register_chain

Emitted when a new foreign chain is registered via governance.

| Attribute | Type | Description |
|-----------|------|-------------|
| `chain_uid` | `string` | The unique chain identifier |
| `name` | `string` | Human-readable chain name |

## hashmerchant_register_contract

Emitted when a CosmWasm contract is registered for sudo callbacks.

| Attribute | Type | Description |
|-----------|------|-------------|
| `contract_addr` | `string` | Bech32 address of the registered contract |
| `chain_uid` | `string` | The chain whose roots the contract will receive |
| `sender` | `string` | The account that paid the escrow |

## hashmerchant_root_confirmed

Emitted when a foreign-chain state root reaches quorum and is written on-chain.

| Attribute | Type | Description |
|-----------|------|-------------|
| `chain_uid` | `string` | The chain this root belongs to |
| `algo` | `string` | Hash algorithm (e.g., `keccak256`, `poseidon`) |
| `attestations` | `string` | Number of validators that attested (stringified integer) |

This is the most important event for indexers and monitoring systems. It signals that a new confirmed root is available and sudo callbacks have been dispatched.
