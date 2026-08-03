<!--
order: 10
-->

# Multi-Source Oracle Aggregation

This document is the **module specification** for modular multi-source attestations inside `x/hashmerchant` vote extensions. It freezes design intent, security rules, and the gap between **current code** and **target sound multi-source aggregation**.

Related: [05_vote_extensions.md](05_vote_extensions.md), [01_concepts.md](01_concepts.md), types in `terp/hashmerchant/v1/types.proto`.

---

## 1. Purpose

Validators may attach **per-source attestations** (price feeds, DB digests, chain RPCs, custom HTTP sources) to `VoteExtensionHashData`, each optionally signed under a **custody authenticator** (limited domain, Penumbra-style).

Two product surfaces share this path:

| Surface | Example | Security claim |
|---------|---------|----------------|
| **Foreign state root (Path B)** | Ethereum `stateRoot` via sidecar | ≥⅔ voting power agreed on the same root bytes |
| **Multi-source modular oracle** | Several custody-signed mids / digests | Root is a **canonical commitment** to those sources; power agrees on that commitment |

Mixing the two without explicit rules is unsafe. This spec separates them.

---

## 2. Data model (proto)

### 2.1 Registered source

```protobuf
message OracleSource {
  string source_id = 1;              // unique within chain_uid
  OracleSourceKind kind = 2;         // postgres, bitcoin_rpc, http, custom, ...
  string endpoint = 3;               // sidecar reference only (not trusted by consensus)
  repeated bytes merkle_prefix = 4;  // optional IBCv2-style membership prefix
  CustodyAuthenticator authenticator = 5;
  bool enabled = 6;
}

message CustodyAuthenticator {
  bytes pubkey = 1;
  string algorithm = 2;  // "ed25519" | "secp256k1" (target)
  string scope = 3;      // e.g. "price/oracle", "merkle_root"
}
```

Sources are registered **per `chain_uid`** (genesis / governance). Sidecars query endpoints; consensus only trusts **signatures + registration + voting power**.

### 2.2 Per-source attestation (in VE)

```protobuf
message OracleAttestation {
  string source_id = 1;
  bytes value = 2;                 // opaque: price JSON, root digest, etc.
  uint64 height = 3;
  int64 timestamp = 4;
  bytes custody_signature = 5;     // over domain-separated payload
  bytes ics23_proof = 6;           // optional
}
```

### 2.3 Vote extension

```protobuf
message VoteExtensionHashData {
  string runtime_id = 1;
  string chain_uid = 2;
  string algo = 3;
  bytes root = 4;
  uint64 foreign_height = 5;
  int64 foreign_block_time = 6;
  bytes ics23_proof = 7;           // optional ICS-23 **or** legacy HMOR bundle
  repeated OracleAttestation attestations = 8;
}
```

**Legacy:** if `attestations` empty, peer verification skips custody (classic single-root path). Optional pack format `HMOR` + JSON in `ics23_proof` for older sidecars.

### 2.4 Custody payload (canonical)

```
domain  = sha256( "hashmerchant/custody/" || scope || "/" || source_id )
payload = domain || value || height_le64 || timestamp_le64
sig     = Sign(algorithm, pubkey, payload)
```

Implementations **must** use little-endian encoding for height and timestamp as in `keeper/oracle.go` today.

---

## 3. Two root models (normative)

### Model A — Foreign state root (`algo` ∈ chain hash_algos, e.g. `keccak256`)

- `root` is the foreign chain state / trie root (or re-hash such as poseidon).
- `attestations` **may** be empty.
- If `attestations` non-empty, they are **annotations** only unless a future policy binds them; they **must not** redefine `root`.
- Quorum on `(chain_uid, algo, root)` is the security property.

### Model B — Multi-source aggregate (`algo` family reserved, e.g. `oracle-agg-v1`)

- `root` **must** equal the **canonical multi-source aggregate** of `attestations` (see §4).
- Empty attestations **must** be rejected for Model B.
- Peer verify **must** reject if `root != Aggregate(attestations)`.
- Quorum on that `root` certifies the **entire attestation set** (because root commits to it).

**Rule:** sidecars and module code **must** select model via `algo` (and/or explicit chain policy). Do not use `keccak256` for pure multi-source price bags.

---

## 4. Canonical multi-source aggregate (target algorithm)

### 4.1 Preconditions

1. `len(attestations) ≥ 1`
2. All `source_id` unique (reject duplicates)
3. Each `source_id` registered, `enabled`, authenticator present
4. Custody signature verifies for each attestation
5. Optional: minimum source set / k-of-n of enabled sources for the `chain_uid` (parameter TBD)

### 4.2 Aggregate-v1 (normative target)

```
// 1. Sort attestations by source_id ascending (bytewise UTF-8)
// 2. For each att in order:
//      chunk = u32be(len(source_id)) || source_id ||
//              u32be(len(value)) || value ||
//              u64le(height) || i64le(timestamp)
// 3. root = sha256( "hashmerchant/oracle-agg/v1" || concat(chunks) )
```

Domain separation string prevents cross-protocol collisions.

### 4.3 Current code status (honest)

| Requirement | Current implementation | Status |
|-------------|------------------------|--------|
| Sort by `source_id` | **Not sorted** (comment claims sorted) | **BUG** |
| Domain-separated aggregate | Plain `sha256(source_id\|\|value)` loop | **INCOMPLETE** |
| Height/timestamp in aggregate | Omitted | **INCOMPLETE** |
| Duplicate source reject | Not enforced | **INCOMPLETE** |
| `root == Aggregate` in Verify | Not checked | **INCOMPLETE** |
| Re-verify custody at Process | Not done | **INCOMPLETE** |
| MarketMode CLOSED | Dead (`_ = params.MarketMode`) | **INCOMPLETE** |
| secp256k1 custody | Proto allows; only ed25519 | **INCOMPLETE** |
| Store prefix for sources | Uses `0x06` (collides with prune epoch key) | **BUG** |

**Until target aggregate + binding land, Model B is not production-sound.** Model A single-root VE remains the supported production path; multi-source values in sudo are **best-effort annotations** under a confirmed root unless Model B is enforced.

---

## 5. Vote extension lifecycle (multi-source aware)

```
ExtendVote
  → HTTP GET sidecar /vote-extension (or empty if no sidecar)
  → fill VoteExtensionHashData (+ attestations)
  → if Model B and root empty: root = Aggregate(atts)  [target: always recompute & check]

VerifyVoteExtension
  → empty ACCEPT
  → unmarshal; chain registered+enabled
  → if attestations non-empty: verify each custody sig
  → TARGET Model B: root == Aggregate; unique sources; min set
  → TARGET: algo allowed for chain

PrepareProposal
  → inject HMVE || ExtendedCommitInfo as first tx when any non-empty VE

ProcessProposal
  → TARGET: validate injected commit vs expected last-commit extensions
  → today: unmarshal-only (weak)

ProcessVoteExtensions (PreBlocker via injected tx)
  → tally power by (chain_uid, algo, root_hex)
  → if power ≥ quorum_fraction * total_power:
       TARGET: re-verify custody + Model B binding
       write HashRoot (include attestations only if identical commitment)
       sudo callbacks
```

### 5.1 Confirmed attestation set

**Target:** because Model B root commits to the full sorted attestation list, all validators who share `root` share the same set; store that set on `HashRoot.attestations`.

**Current:** stores `votes[0].attestations` only — **not** multi-source consensus. Must not be treated as quorum-certified per-source data.

---

## 6. Sudo delivery of sources

When a root is confirmed, registered contracts receive (extension of [06_sudo_interface](06_sudo_interface.md)):

```json
{
  "hash_merchant": {
    "chain_uid": "...",
    "algo": "...",
    "height": 0,
    "root": "<bytes>",
    "attestation_count": 0,
    "block_time": 0,
    "oracle_sources": [
      { "source_id": "skip-connect", "value": "<bytes>", "height": 0 }
    ]
  }
}
```

**Normative trust for contracts:**

- Trust **module** for `root` + `oracle_sources` only after Model B fixes, **or**
- Treat `oracle_sources` as **hints**: apply app-level stale/bps policy; never mint supply from oracle (see loyalty/NFT handoffs).

Custody signatures are **not** currently passed in sudo; on-chain re-verify of custody is not required if the module consensus path is sound.

---

## 7. Sidecar HTTP contract (runtime)

See also `tools/hashmerchant-support/sidecar-api.md` and `crates/terp-rs/tools/hash-market`.

```
GET /health → { "status": "ok" }
GET /vote-extension → VoteExtension JSON:

{
  "runtime_id": "...",
  "chain_uid": "...",
  "algo": "keccak256" | "oracle-agg-v1",
  "root": "<hex>",
  "foreign_height": 0,
  "foreign_block_time": 0,
  "attestations": [
    {
      "source_id": "...",
      "value": "<hex>",
      "height": 0,
      "timestamp": 0,
      "custody_signature": "<hex ed25519>"
    }
  ]
}
```

Node: `hashmerchant.sidecar-url` / `HASHMERCHANT_SIDECAR_URL`. Empty → empty VE.

---

## 8. Implementation roadmap (module)

| Priority | Work | Outcome |
|----------|------|---------|
| P0 | Fix store prefix collision (`0x06` prune vs oracle sources → use `0x07` for sources) | Correct KV |
| P0 | Sort + domain-separated Aggregate-v1; unit tests order-independence | Deterministic multi-source |
| P0 | Verify + Process: bind root when `algo` is aggregate family | Model B soundness |
| P1 | Re-verify custody at Process; reject duplicate source_id | Defense in depth |
| P1 | Enforce MarketMode CLOSED (validator and/or source allowlist) | Param meaning |
| P1 | Update HashRoot attestation set only when digest matches root | Honest multi-source store |
| P2 | secp256k1 custody; min sources param; ProcessProposal commit checks | Production harden |
| P2 | Spec/tests aligned with hash-market modular matrix | E2E parity |

---

## 9. Testing requirements

1. **Unit:** Aggregate order-independence; height/ts inclusion; duplicate reject.  
2. **Unit:** Verify rejects wrong root for Model B; accepts Model A with empty atts.  
3. **Keeper:** Process writes one root under quorum; empty VE ignored.  
4. **Custody:** ed25519 verify positive/negative (existing `oracle_test.go` seed).  
5. **E2E:** Path B Anvil (`tests/tsh/hashmerchant`) remains green for Model A.  
6. **E2E (later):** multi-source Model B with hash-market / ICT (see ICT bootstrap handoff).

---

## 10. Non-goals

- Light-client-grade verification of foreign ICS-23 inside every VE (optional field only).  
- Oracle minting of balances or NFT supply.  
- Sidecar endpoint strings as consensus inputs.  
- Replacing validator voting power with “source reputation” alone.

---

## 11. References

| Code / doc | Role |
|------------|------|
| `x/hashmerchant/keeper/oracle.go` | Custody + aggregate (current) |
| `x/hashmerchant/keeper/vote_ext.go` | Extend / Verify / Process / sudo |
| `x/hashmerchant/keeper/abci.go` | HMVE injection |
| `x/hashmerchant/keeper/oracle_bundle.go` | HMOR legacy |
| `x/hashmerchant/keeper/oracle_store.go` | Source registration store |
| `crates/terp-rs/tools/hash-market` | In-house multi-source runtime / relay |
| `tools/hashmerchant-support/` | Operator install façade |
| `docs/bootstrap/hashmerchant-nft-oracle-minter-handoff.md` | Consumer contracts |
| [11_oracle_consumer_guide.md](11_oracle_consumer_guide.md) | Integration / consumer how-to |

---

*Normative for new work. Prefer implementing P0 before claiming multi-source price consensus.*
