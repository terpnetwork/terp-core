<!--
order: 4
-->

# Messages

The `x/hashmerchant` module defines four transaction message types. Two are governance-gated (require the `x/gov` module address as authority), and two are permissionless.

## MsgRegisterChain

**Authorization**: Governance-only

Adds a foreign chain to the registry, enabling validators to attest to its state roots.

| Field | Type | Description |
|-------|------|-------------|
| `authority` | `string` | Must be the governance module address |
| `chain` | `RegisteredChain` | The chain definition to register |

**RegisteredChain fields:**

| Field | Type | Description |
|-------|------|-------------|
| `chain_uid` | `string` | Unique identifier (e.g., `ethereum-mainnet`, `cosmoshub-4`) |
| `name` | `string` | Human-readable label |
| `rpc_endpoints` | `[]string` | Reference RPC endpoints for sidecars |
| `hash_algos` | `[]string` | Supported hash algorithms (e.g., `keccak256`, `poseidon`) |
| `enabled` | `bool` | Whether attestation is active |

**Validation:**
- `authority` must match the governance module address
- `chain_uid` must not already exist in the registry

**Events emitted:** `hashmerchant_register_chain`

## MsgRegisterContract

**Authorization**: Permissionless (requires escrow payment)

Registers a CosmWasm contract to receive sudo callbacks when hash roots are confirmed for a specific chain.

| Field | Type | Description |
|-------|------|-------------|
| `sender` | `string` | The account paying the escrow |
| `contract_addr` | `string` | Bech32 address of the CosmWasm contract |
| `chain_uid` | `string` | Which chain's roots this contract wants |
| `substore_keys` | `[]string` | Optional: specific substores of interest |
| `escrow` | `Coin` | Escrow payment (must be >= `min_escrow_amount` in `escrow_denom`) |

**Validation:**
- Target `chain_uid` must exist and be enabled
- `escrow.denom` must match `params.escrow_denom`
- `escrow.amount` must be >= `params.min_escrow_amount`
- Sender must have sufficient balance

**State changes:**
- Escrow transferred from sender to `hashmerchant` module account
- `RegisteredContract` stored at `0x02 | contract_addr`
- `EscrowRecord` stored at `0x03 | contract_addr`

**Events emitted:** `hashmerchant_register_contract`

## MsgRefillEscrow

**Authorization**: Permissionless

Adds more escrow to an existing contract registration, extending the `paid_until_height`.

| Field | Type | Description |
|-------|------|-------------|
| `sender` | `string` | The account paying the additional escrow |
| `contract_addr` | `string` | The contract to refill |
| `amount` | `Coin` | Additional escrow to deposit |

**Validation:**
- `contract_addr` must have an existing `EscrowRecord`
- `amount.denom` must match `params.escrow_denom`
- Sender must have sufficient balance

**State changes:**
- Additional escrow transferred to module account
- `EscrowRecord.paid_until_height` extended
- `EscrowRecord.amount` increased by refill amount

## MsgUpdateParams

**Authorization**: Governance-only

Updates the module parameters.

| Field | Type | Description |
|-------|------|-------------|
| `authority` | `string` | Must be the governance module address |
| `params` | `Params` | The new parameter values |

**Validation:**
- `authority` must match the governance module address
- `params.quorum_fraction` must be in `[0, 1]`
- `params.prune_interval` must be > 0
- `params.escrow_denom` must not be empty
- `params.min_escrow_amount` must be >= 0

**CLI:**

```bash
# Register a contract for Ethereum root callbacks (1 TERP escrow)
terpd tx hashmerchant register-contract \
  terp1contractaddr... \
  ethereum-mainnet \
  "bank,staking" \
  1000000uterp \
  --from mykey

# Refill escrow (add 5 more TERP)
terpd tx hashmerchant refill-escrow \
  terp1contractaddr... \
  5000000uterp \
  --from mykey
```
