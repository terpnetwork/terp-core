<!--
order: 11
-->

# Oracle integration and consumer guide

This guide tells a new developer how to **consume** hashmerchant-confirmed roots and multi-source oracle attestations without reading the full module source.

It is grounded in the current module surface (`x/hashmerchant`) and the multi-source design in [10_multi_source_oracle.md](10_multi_source_oracle.md). It does **not** describe external “thiol”, third-party price-module, or invented gRPC APIs.

| Related | Path |
|---------|------|
| Multi-source design (normative gaps) | [10_multi_source_oracle.md](10_multi_source_oracle.md) |
| Sudo trait for contracts | [06_sudo_interface.md](06_sudo_interface.md) |
| Parameters | [08_parameters.md](08_parameters.md) |
| Vote extensions | [05_vote_extensions.md](05_vote_extensions.md) |
| Keeper (custody / aggregate today) | `x/hashmerchant/keeper/oracle.go` |
| Minimal CosmWasm consumer | `tests/tsh/hashmerchant/contracts/hashmerchant-test/` |
| NFT / price-sync product handoff | `docs/bootstrap/hashmerchant-nft-oracle-minter-handoff.md` |

---

## 1. Architecture overview (consumer view)

```
Sidecar (hash-market / operator runtime)
  |  GET /vote-extension  →  VoteExtensionHashData { root, algo, attestations[] }
  v
Validators (ABCI++ vote extensions)
  |  VerifyVoteExtension: chain enabled; optional ed25519 custody on attestations
  v
Module tally (voting power on (chain_uid, algo, root))
  |  if power ≥ quorum_fraction × total_bonded
  v
HashRoot written on-chain
  |  optional sudo → registered CosmWasm contracts (escrow active)
  v
Consumers
  - CosmWasm: sudo + own storage, or query another contract
  - Off-chain / other modules: gRPC Query { HashRoot, HashRoots, RegisteredChain, Params }
```

Two security models share the same wire path (see §3 of the multi-source spec):

| Model | Typical `algo` | What quorum certifies | Consumer takeaway **today** |
|-------|----------------|----------------------|-----------------------------|
| **A — foreign state root** | e.g. `keccak256`, chain hash algos | The `root` bytes | Production path for Path B / Merkle proofs |
| **B — multi-source aggregate** | reserved family e.g. `oracle-agg-v1` | Aggregate of sorted attestations | **Not production-sound yet** (aggregate binding incomplete) |

Until Model B P0 work lands, treat `oracle_sources` / `HashRoot.attestations` as **module-delivered annotations under a power-quorum root**, not as independently quorum-certified per-source prices. Always apply app-level staleness and sanity checks (see §6).

There is **no** separate “price oracle module” API. Prices (if any) are opaque `value` bytes on `OracleAttestation` / sudo `oracle_sources`, usually JSON such as `{"asset":"BTC","price_usd":"95000.00"}` (see `oracle_test.go`).

---

## 2. How consumers get data

### 2.1 CosmWasm: push via `sudo` (primary on-chain path)

When a root is confirmed, the module calls `WasmKeeper.Sudo` on every **enabled** `RegisteredContract` whose `chain_uid` matches and whose escrow `paid_until_height` is still current.

Envelope (from `keeper/vote_ext.go`):

```json
{
  "hash_merchant": {
    "chain_uid": "ethereum-mainnet",
    "algo": "keccak256",
    "height": 19500000,
    "root": "<base64 of root bytes>",
    "attestation_count": 85,
    "block_time": 1710000000,
    "oracle_sources": [
      {
        "source_id": "skip-connect",
        "value": "<bytes of attested payload>",
        "height": 19500000
      }
    ]
  }
}
```

Notes:

- `attestation_count` is the number of **validators** in the winning root tally, not the number of oracle sources.
- `oracle_sources` is omitted when empty. Each entry currently carries `source_id`, `value`, `height` only (no custody signature in sudo).
- JSON encoding of `root` / `value` follows standard Go `encoding/json` for `[]byte` (base64). Decode before comparing to hex proofs.

#### Rust types (minimal consumer)

Aligned with `tests/tsh/hashmerchant/contracts/hashmerchant-test/src/msg.rs`, extended with optional oracle sources:

```rust
use cosmwasm_schema::cw_serde;
use cosmwasm_std::Binary;

#[cw_serde]
pub struct HashMerchantSudoMsg {
    pub hash_merchant: HashMerchantSudoPayload,
}

#[cw_serde]
pub struct HashMerchantSudoPayload {
    pub chain_uid: String,
    pub algo: String,
    pub height: u64,
    /// Module sends raw root bytes; CosmWasm JSON usually surfaces this as base64.
    pub root: Binary,
    pub attestation_count: u32,
    pub block_time: i64,
    #[serde(default)]
    pub oracle_sources: Vec<OracleSourceHint>,
}

#[cw_serde]
pub struct OracleSourceHint {
    pub source_id: String,
    pub value: Binary,
    pub height: u64,
}
```

#### Example: store root + optional price mid

```rust
use cosmwasm_std::{entry_point, DepsMut, Env, Response, StdError, StdResult};
use cw_storage_plus::Map;
use serde_json::Value;

const ROOTS: Map<(&str, &str), HashMerchantSudoPayload> = Map::new("hm_roots");
const PRICE_MIDS: Map<&str, (String, u64, i64)> = Map::new("price_mids"); // asset → (mid, src_height, block_time)

#[entry_point]
pub fn sudo(deps: DepsMut, env: Env, msg: HashMerchantSudoMsg) -> StdResult<Response> {
    let p = msg.hash_merchant;

    // 1) Always persist the confirmed root (Model A security property).
    ROOTS.save(deps.storage, (&p.chain_uid, &p.algo), &p)?;

    // 2) Optional: parse price-shaped attestation values with hard safety gates.
    for src in &p.oracle_sources {
        // Staleness vs foreign height / wall clock — policy is APP-DEFINED.
        if p.block_time > 0 {
            let age = env.block.time.seconds() - p.block_time;
            if age > 300 {
                // Skip applying price; still keep the root above.
                continue;
            }
        }

        let raw = String::from_utf8(src.value.to_vec())
            .map_err(|_| StdError::generic_err("oracle value not utf8"))?;
        let v: Value = serde_json::from_str(&raw)
            .map_err(|_| StdError::generic_err("oracle value not json"))?;

        let asset = v.get("asset").and_then(|x| x.as_str()).unwrap_or("");
        let price = v.get("price_usd").and_then(|x| x.as_str()).unwrap_or("");
        if asset.is_empty() || price.is_empty() || price == "0" || price.starts_with('-') {
            continue; // never assume non-zero / well-formed prices
        }

        PRICE_MIDS.save(
            deps.storage,
            asset,
            &(price.to_string(), src.height, p.block_time),
        )?;
    }

    Ok(Response::new()
        .add_attribute("action", "hash_merchant_sudo")
        .add_attribute("chain_uid", p.chain_uid)
        .add_attribute("algo", p.algo))
}
```

Reference lab contract: `tests/tsh/hashmerchant/contracts/hashmerchant-test/` (stores root only; extend as above for prices).

#### Register the contract for callbacks

```bash
# CLI (x/hashmerchant/client/cli/tx.go)
terpd tx hashmerchant register-contract \
  <contract-addr> <chain-uid> <substore-keys-csv> <escrow-amount> \
  --from <key> --chain-id <id> -y

# Example
terpd tx hashmerchant register-contract \
  terp1contract... ethereum-mainnet bank,staking 1000000uterp \
  --from alice -y
```

Requirements (enforced in `msg_server.go`):

- Target `chain_uid` is registered and `enabled`
- Escrow denom matches `params.escrow_denom` (default `uterp`)
- Escrow amount ≥ `params.min_escrow_amount` (default `1000000`)
- Escrow buys callback windows:  
  `paid_until = height + (amount / min_escrow_amount) * prune_interval`

Keep escrow alive with `terpd tx hashmerchant refill-escrow <contract-addr> <amount>`.

### 2.2 Off-chain or other modules: gRPC / CLI query

Query service: `terp.hashmerchant.v1.Query` (`proto/terp/hashmerchant/v1/query.proto`).

| RPC | Purpose | CLI (where present) |
|-----|---------|---------------------|
| `Params` | Quorum, escrow, market_mode | `terpd q hashmerchant params` |
| `RegisteredChain` / `RegisteredChains` | Chain metadata + `oracle_sources` config on the chain object | `terpd q hashmerchant chain <uid>` / `chains` |
| `HashRoot` | Latest confirmed root for `(chain_uid, algo)` including `attestations` | `terpd q hashmerchant root <chain-uid> <algo>` |
| `HashRoots` | All roots for a chain | gRPC / REST only (no dedicated CLI today) |
| `RegisteredContract` / `RegisteredContracts` | Callback registration | gRPC |
| `Escrow` | Paid-until height | `terpd q hashmerchant escrow <addr>` |

Examples:

```bash
# Latest confirmed root + any stored attestations
terpd q hashmerchant root ethereum-mainnet keccak256 -o json

# Chain registration (includes configured OracleSource entries when set at register/genesis)
terpd q hashmerchant chain ethereum-mainnet -o json

terpd q hashmerchant params -o json
```

gRPC-gateway REST paths follow the proto annotations under `/terp/hashmerchant/v1/...` (see generated `query.pb.gw.go`).

#### Go query client (app / relayer)

```go
import (
    "context"

    "github.com/terpnetwork/terp-core/v5/x/hashmerchant/types"
    "google.golang.org/grpc"
)

func latestRoot(conn grpc.ClientConnInterface, chainUID, algo string) (*types.HashRoot, error) {
    qc := types.NewQueryClient(conn)
    res, err := qc.HashRoot(context.Background(), &types.QueryHashRootRequest{
        ChainUid: chainUID,
        Algo:     algo,
    })
    if err != nil {
        return nil, err
    }
    return &res.Root, nil
}

// Inspect multi-source hints (opaque value bytes). Do not treat as Model B certified
// until root == Aggregate(attestations) is enforced on-chain.
func firstPriceJSON(root *types.HashRoot, sourceID string) []byte {
    for _, a := range root.Attestations {
        if a != nil && a.SourceId == sourceID {
            return a.Value
        }
    }
    return nil
}
```

#### Go keeper usage (in-process modules)

Other modules may depend on the hashmerchant keeper only if the app wires it. There is **no** separate “price” keeper method. Public store helpers used by the module include:

```go
// x/hashmerchant/keeper/keeper.go
GetHashRoot(ctx, chainUID, algo) (types.HashRoot, error)
IterateHashRoots(ctx, chainUID, cb)

// x/hashmerchant/keeper/oracle_store.go
GetOracleSources(ctx, chainUID) ([]types.OracleSource, error) // registration list for custody verify
```

There is currently **no** gRPC `QueryOracleSources`; consumers read source registration from `RegisteredChain.oracle_sources` (when present on the chain record) and live values from `HashRoot.attestations` / sudo `oracle_sources`.

Example keeper-side consumer pattern:

```go
root, err := hmKeeper.GetHashRoot(ctx, "prices-btc-usd", "keccak256")
if err != nil {
    return err // types.ErrHashRootNotFound when missing
}
if root.BlockTime == 0 {
    // policy: reject missing foreign timestamp
}
// Staleness against ctx.BlockTime().Unix()
if ctx.BlockTime().Unix()-root.BlockTime > 300 {
    return fmt.Errorf("stale oracle root")
}
```

---

## 3. Configuration guide

### 3.1 Register a chain (governance)

`MsgRegisterChain` is authority-gated (`msg_server.RegisterChain`). Include supported `hash_algos` and optional modular `oracle_sources`:

```json
{
  "chain_uid": "prices-composite-1",
  "name": "Composite price bag",
  "rpc_endpoints": ["http://sidecar:8080"],
  "hash_algos": ["keccak256", "oracle-agg-v1"],
  "enabled": true,
  "oracle_sources": [
    {
      "source_id": "skip-connect",
      "kind": "ORACLE_SOURCE_KIND_HTTP",
      "endpoint": "http://localhost:8081/mid",
      "enabled": true,
      "authenticator": {
        "pubkey": "<32-byte ed25519 pubkey>",
        "algorithm": "ed25519",
        "scope": "price/oracle"
      }
    }
  ]
}
```

Genesis also loads `RegisteredChain.oracle_sources` into the oracle sources store (`InitGenesis` → `SetOracleSources`).

**Custody today:** only `algorithm = "ed25519"` is verified (`verifyOracleAttestations`). secp256k1 is not implemented. Empty attestations skip custody (legacy Model A).

### 3.2 Add or change price feeds

| Step | Who | How |
|------|-----|-----|
| Add `OracleSource` (id, kind, endpoint, custody pubkey, scope, enabled) | Governance / genesis | `MsgRegisterChain` or chain update path when available; sources mirrored via `SetOracleSources` |
| Sidecar polls endpoint and signs value | Operators / hash-market | Sidecar HTTP contract in §7 of multi-source spec |
| Validators enable sidecar | Operators | `hashmerchant.sidecar-url` / `HASHMERCHANT_SIDECAR_URL` |
| Consumers map `source_id` → asset policy | App developers | Contract config / params (not module-enforced) |

`endpoint` is **not** consensus input. Consensus trusts signatures + registration + voting power (and, for Model A, agreement on `root`).

### 3.3 Update thresholds and market mode

Module params (`MsgUpdateParams`, governance):

| Param | Default | Consumer relevance |
|-------|---------|-------------------|
| `quorum_fraction` | `0.667` | How much VP must share the same `root` |
| `prune_interval` | `1000` | Escrow unit; sudo stops when paid_until lapses |
| `escrow_denom` / `min_escrow_amount` | `uterp` / `1e6` | Cost to stay registered |
| `market_mode` | `OPEN` | Intended CLOSED allowlist; **CLOSED not enforced yet** (`_ = params.MarketMode` in oracle verify) |

There is **no** on-chain “max price age” or “max bps deviation” param. Those are **application policy** (contract storage or keepers). Document and enforce them in the consumer.

### 3.4 Relayers / sidecars

Runtime contract (summary):

```
GET /health → { "status": "ok" }
GET /vote-extension → VoteExtensionHashData JSON
  (root hex, algo, foreign_height, foreign_block_time, attestations[])
```

In-house multi-source tooling lives under `crates/terp-rs/tools/hash-market` and operator façade `tools/hashmerchant-support/`. Empty sidecar URL → empty vote extension (no root that round).

Legacy pack: `HMOR` + JSON in `ics23_proof` (`oracle_bundle.go`) for older sidecars.

---

## 4. Deployment and upgrade

### 4.1 Lab / Path B (Model A root mirror)

1. Register chain with foreign hash algo (e.g. `keccak256`).
2. Run mock or real sidecar that supplies `root` matching the foreign head.
3. Validators with vote extensions enabled.
4. Deploy consumer contract; `register-contract` + escrow.
5. Confirm event `hashmerchant_root_confirmed` and contract storage / sudo attributes.
6. E2E scripts: `tests/tsh/hashmerchant/` (see field docs under `docs/hashmerchant/`).

### 4.2 Multi-source price bag (Model B target)

1. Read [10_multi_source_oracle.md](10_multi_source_oracle.md) §4–§8 for **honest** current gaps (unsorted aggregate, no root binding, store prefix collision, etc.).
2. Do **not** claim production multi-source price consensus until P0 items land.
3. Prefer Model A `root` for security-critical actions; treat per-source values as hints with app policy.

### 4.3 Upgrades

| Layer | Guidance |
|-------|----------|
| Module binary | Standard Cosmos SDK upgrade; export/import genesis includes `HashRoots`, chains, contracts, escrow, params |
| Aggregate algorithm | Domain string `hashmerchant/oracle-agg/v1` is versioned; consumers should not hardcode aggregate roots until enforced on-chain |
| Sudo schema | Additive fields (`oracle_sources`) are optional; use `#[serde(default)]` / omitempty-friendly types |
| Price JSON | Version your own schema inside `value` bytes; module does not version price payloads |
| Escrow | Survives upgrade via genesis export; refill if `paid_until` nears |

---

## 5. Query and attest examples (cheat sheet)

### 5.1 Confirm a root exists

```bash
terpd q hashmerchant root ethereum-mainnet keccak256 -o json
# → chain_uid, algo, height, root, attestation_count, block_time, attestations[]
```

### 5.2 CosmWasm: reject mint when price stale or zero

```rust
pub fn assert_fresh_mid(
    deps: Deps,
    env: &Env,
    asset: &str,
    max_age_secs: i64,
) -> StdResult<String> {
    let (mid, _src_h, block_time) = PRICE_MIDS.load(deps.storage, asset)?;
    if mid.is_empty() || mid == "0" {
        return Err(StdError::generic_err("zero or empty mid"));
    }
    if block_time <= 0 {
        return Err(StdError::generic_err("missing block_time on price update"));
    }
    let age = env.block.time.seconds() - block_time;
    if age > max_age_secs {
        return Err(StdError::generic_err(format!("stale price age={age}s")));
    }
    Ok(mid)
}
```

### 5.3 Custody payload (for operators signing attestations)

From `keeper/oracle.go` (must match exactly):

```
domain  = sha256( "hashmerchant/custody/" || scope || "/" || source_id )
payload = domain || value || height_le64 || timestamp_le64
sig     = ed25519.Sign(priv, payload)
```

Height and timestamp are **little-endian** 8-byte integers. Scope example used in tests: `"price/oracle"`.

### 5.4 Current aggregate (incomplete — do not rely on for Model B)

```go
// keeper/oracle.go — NOT sorted; omits height/timestamp/domain
// Target Aggregate-v1 is specified in 10_multi_source_oracle.md §4.2
func aggregateAttestationRoot(attestations []types.OracleAttestation) []byte {
    h := sha256.New()
    for _, att := range attestations {
        h.Write([]byte(att.SourceId))
        h.Write(att.Value)
    }
    return h.Sum(nil)
}
```

---

## 6. Security considerations for consumers

These rules are the **acceptance checklist** for integrators:

1. **Check staleness.** Prefer `HashRoot.block_time` / sudo `block_time` and your own max-age. Do not assume every block updates the root.
2. **Do not assume non-zero prices.** Empty `value`, missing JSON keys, `"0"`, negative, or non-numeric strings must fail closed for financial actions.
3. **Trust model honesty.**
   - Model A: trust the quorum-confirmed `root` for Merkle membership.
   - Multi-source fields today: **hints** under that root (or under a non-bound bag). Do not mint token/NFT supply solely from `oracle_sources` (see NFT handoff and multi-source non-goals).
4. **`attestation_count` is validator count**, not source diversity. High count does not mean many independent price APIs agreed.
5. **Custody not re-verified in sudo.** Signatures are checked on vote-extension verify for non-empty attestations; Process does not currently re-verify; sudo does not pass signatures. Harden at the module layer before relying on per-source crypto in contracts.
6. **Escrow expiry** silently stops sudo. Design keepers/contracts to degrade safely when updates stop (last-good with TTL, or halt).
7. **Algo selection.** Do not use foreign hash algos (e.g. `keccak256`) as if they were multi-source aggregate commitments. Reserved aggregate algos are not fully enforced yet.
8. **No module-level bps band.** Implement deviation checks against a TWAP, previous mid, or secondary source in the consumer.
9. **Store / genesis quirks** (operators): oracle sources key prefix currently collides with prune epoch key (`0x06`) per multi-source spec — treat source registration carefully until P0 fix.
10. **MarketMode CLOSED** is documented but not enforced in verify; do not rely on it for allowlisting.

---

## 7. What this guide deliberately does not document

- Any **thiol** or non-hashmerchant price API
- Invented RPCs such as `QueryPrice` / `GetMid` (they do not exist on this module)
- Claiming Model B multi-source consensus is production-ready
- Light-client-grade ICS-23 verification of every foreign proof (optional field only)
- Sidecar endpoint strings as consensus truth

---

## 8. Acceptance mapping (task checklist)

| Requirement | Where covered |
|-------------|----------------|
| How contracts/modules query prices / roots | §2 (sudo, gRPC, keeper) |
| Code examples (CosmWasm + Go) | §2.1, §2.2, §5 |
| Config: feeds, thresholds, relayers | §3 |
| Deployment / upgrade | §4 |
| Consumer security (staleness, non-zero, trust) | §6 |
| Architecture + design doc | §1 + link to `10_multi_source_oracle.md` |

*Integrators: start with Model A root consumption, add optional price hints with strict policy, and track multi-source P0 before treating `oracle_sources` as consensus truth.*
