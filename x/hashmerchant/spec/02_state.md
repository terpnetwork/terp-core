<!--
order: 2
-->

# State

The `x/hashmerchant` module uses a single KVStore with the store key `hashmerchant`. All records are protobuf-encoded and keyed by a one-byte prefix followed by a human-readable identifier.

## Store Layout

| Prefix | Key Format | Value | Description |
|--------|-----------|-------|-------------|
| `0x01` | `0x01 \| chain_uid` | `RegisteredChain` | Foreign chain registry |
| `0x02` | `0x02 \| contract_addr` | `RegisteredContract` | Contract registrations |
| `0x03` | `0x03 \| contract_addr` | `EscrowRecord` | Escrow deposits |
| `0x04` | `0x04 \| chain_uid \| "\|" \| algo` | `HashRoot` | Confirmed state roots |
| `0x05` | `0x05` | `Params` | Module parameters |
| `0x06` | `0x06` | `uint64` | Last prune epoch height |

## Data Structures

### RegisteredChain

A foreign chain that validators can attest to.

```protobuf
message RegisteredChain {
  string          chain_uid     = 1;  // e.g. "ethereum-mainnet", "cosmoshub-4"
  string          name          = 2;  // human-readable label
  repeated string rpc_endpoints = 3;  // reference endpoints for sidecars
  repeated string hash_algos    = 4;  // e.g. ["keccak256", "poseidon"]
  bool            enabled       = 5;  // governance can disable attestation
}
```

Only governance (`MsgRegisterChain`) can add or modify chains. The `chain_uid` is the primary key and must be unique.

### RegisteredContract

A CosmWasm contract that receives hash root callbacks.

```protobuf
message RegisteredContract {
  string          contract_addr  = 1;  // bech32 contract address
  string          chain_uid      = 2;  // which chain's roots to receive
  repeated string substore_keys  = 3;  // optional: specific substores of interest
  bool            enabled        = 4;  // false when escrow expires
}
```

### EscrowRecord

Tracks how much a contract has paid and how long its subscription lasts.

```protobuf
message EscrowRecord {
  string                   contract_addr    = 1;
  cosmos.base.v1beta1.Coin amount           = 2;  // total deposited
  uint64                   paid_until_height = 3;  // callbacks stop after this
  uint64                   last_prune_height = 4;  // bookkeeping
}
```

When `block_height > paid_until_height`, the associated `RegisteredContract` is disabled during the next prune cycle.

### HashRoot

A validator-confirmed foreign-chain state root.

```protobuf
message HashRoot {
  string chain_uid         = 1;  // e.g. "ethereum-mainnet"
  string algo              = 2;  // e.g. "keccak256" or "poseidon"
  uint64 height            = 3;  // foreign chain block height
  bytes  root              = 4;  // the state root hash (32 bytes)
  uint32 attestation_count = 5;  // number of validators that attested
  int64  block_time        = 6;  // foreign chain block timestamp (unix seconds)
}
```

The store key is `0x04 | chain_uid | "|" | algo`, meaning only the **latest** confirmed root per `(chain_uid, algo)` pair is stored. Historical roots are not retained on-chain (contracts should store them if needed).

### HashPairTicket

A helper type linking an origin-chain hash to its destination-chain representation.

```protobuf
message HashPairTicket {
  string project_id          = 1;
  bytes  origin_hash         = 2;  // e.g. keccak256 root
  bytes  destination_hash    = 3;  // e.g. poseidon re-hash
  string zk_circuit_id       = 4;
  uint64 destination_chain_id = 5;
  uint64 expiry_block        = 6;
  bytes  metadata            = 7;
}
```

### VoteExtensionHashData

The payload validators embed in their ABCI++ vote extensions.

```protobuf
message VoteExtensionHashData {
  string runtime_id         = 1;
  string chain_uid          = 2;
  string algo               = 3;
  bytes  root               = 4;
  uint64 foreign_height     = 5;
  int64  foreign_block_time = 6;
  bytes  ics23_proof        = 7;  // optional ICS-23 commitment proof
}
```

## Parameters

Stored at prefix `0x05`. See [Parameters](08_parameters.md) for full documentation.

```protobuf
message Params {
  string    quorum_fraction   = 1;  // LegacyDec, default "0.667"
  uint64    prune_interval    = 2;  // default 1000 blocks
  string    escrow_denom      = 3;  // default "uterp"
  math.Int  min_escrow_amount = 4;  // default 1,000,000 (1 TERP)
  MarketMode market_mode      = 5;  // default OPEN
}
```
