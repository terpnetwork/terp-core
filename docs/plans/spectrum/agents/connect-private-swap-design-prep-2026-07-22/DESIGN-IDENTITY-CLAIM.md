# DESIGN-IDENTITY-CLAIM

| Field | Value |
|-------|--------|
| **Date** | 2026-07-22 |
| **Track** | IDENTITY-CLAIM (G1) |
| **Mode** | Design freeze only — no large product implementation this round |
| **Board** | `private-bridge-corridor` |
| **Prior** | `btc-terp-zec-full-e2e-prep-2026-07-22` Phase A (O-G1–3, M1–2, M7, M11) |

## 0. Track charter

| Field | Value |
|-------|--------|
| **Goal (one sentence)** | Freeze the continuous deposit → `BridgeMintClaimPublic` builder so observe/watch fields deterministically set ν, `value_u64`, and dest, fail-closed when incomplete. |
| **Closes gap ID** | **G1** (synthesis Phase A / T1) |
| **Depends on handoffs** | **G4 DEST-SEAL**: watch `dest_owner_binding` is 32-byte hex from golden/live seal (not invented here). Observe plane types already green. |
| **Produces handoffs** | Provisional ν rule + domain tag; `claim_from_deposit_watch` signature + field map; claim-inputs GET sketch; fail-closed error set; lab policy labels (`mock_verify` / membership flags). Downstream: **G2** note value/owner/ν lineage; **G3** harness mint wire. |

### Scope

**Owns**
- Provisional nullifier rule (pure fn + domain tag)
- `claim_from_deposit_watch(obs, watch, policy) → BridgeMintClaimPublic` (or equivalent pure builder)
- Optional: `GET /corridor/claim-inputs/:intent_id` response shape (API sketch; hint-only)
- `value_u64 ← amount_sats` (scale via policy)
- `dest_commitment / burn_dest_commitment ← dest_owner_binding` (G4 source)
- Lab flags / `mock_verify` still allowed; must be labeled

**Does not own**
- Harness shell wiring / Daemon execute (G3)
- Swap spend openings (G2)
- Zakura RPC / golden generation (G4 implementation) — only dest field **source contract**
- SP1 / `mock_verify=false` production verify (D7 residual)
- Amending D1–D7 freezes
- Mainnet claims

---

## 1. Current code reality (cite paths)

| Surface | Status | Path / command |
|---------|--------|----------------|
| `DepositWatch` / `DepositObservation` | Green coord | `crates/terp-rs/tools/hash-market/src/corridor_deposits.rs` |
| Watch open + observe HTTP | Green | `POST /corridor/watches`, `POST /corridor/observations`; `server.rs` |
| Reporter posts real `txid` / `amount_sats` | Green (funded) | `btc_index/reporter.rs`; `AddressFunding` **has** `vout` |
| Observation drops `vout` | Gap | `DepositObservation` has no `vout` field today |
| `BridgeMintClaimPublic` + pure authorize | Green | `crates/headstash/contracts/cw-headstash/src/bridge.rs` |
| `derive_claim_id_with_dest` / `derive_domain_binding` | Green | same `bridge.rs` (`TERP_BRIDGE_CLAIM_TAG`, `TERP_PRIVATE_BRIDGE_DOMAIN_TAG`) |
| Once-per-claim storage | Green | `bridge_claim_storage_key(ν)` = `bridge:02:{hex(ν)}` |
| Chain funded mint | Green **fixture** | `test-press/src/bin/corridor_ict_funded.rs` + `BridgeL1World::happy()` / `configure_bridge_happy` |
| Happy claim identity | Synthetic | `happy_bridge_mint_world()`: ν = `sha256("nu-hinge-happy")`, value = `1_000_000`, dest = `sha256("dest-commitment-A")` |
| Pure film ν bind | Partial | `cashapp_zec_corridor.rs` `bridge_mint_for_intent`: ν := `intent.btc_txid_or_intent_id` after `bind_deposit_id` — not from hash-market JSON |
| Observe → claim mapper | **Missing** | No pure/product path builds claim from obs+watch |
| claim-inputs API | **Missing** | No `GET /corridor/claim-inputs/:intent_id` |
| Funded e2e dataflow | Uncoupled | `docs/plans/spectrum/e2e/corridor-ict-funded.sh` sequences observe then mint without field pass |

### Continuity today

```text
observe(intent_A, real txid, amount)  ──label only──►  mint(fixture ν, fixture value, fixture dest)
```

---

## 2. Target interface (freeze)

### 2.1 Provisional nullifier (normative)

**Domain tag (exact bytes):**

```rust
/// Provisional corridor deposit nullifier domain (not Tacit LC burn ν).
/// Label: lab / continuous-identity until true BTC confidential burn ν exists.
pub const TERP_BTC_DEPOSIT_NU_V0: &[u8] = b"terp-btc-deposit-nu-v0";
```

**Rule (exact preimage order):**

```text
nullifier = SHA256(
    TERP_BTC_DEPOSIT_NU_V0
    ‖ txid_bytes[32]
    ‖ vout.to_be_bytes()[4]
    ‖ intent_id.as_bytes()     // UTF-8, as stored on watch/obs
)
```

**Encoding freezes:**

| Input | Encoding |
|-------|----------|
| `txid` | Decode observation `txid` hex (optional `0x` strip; case-insensitive) → **exactly 32 raw bytes**. Hash those bytes. **Do not** reverse-endian after decode (use the same hex string the reporter/hub posted). |
| `vout` | `u32` big-endian 4 bytes. Required for continuous claim path. |
| `intent_id` | UTF-8 bytes of the hub string (no extra null terminator). Must match watch and observation. |

**Properties:**
- Deterministic; same deposit outpoint + intent → same ν → same once-per-claim key under `NF_BRIDGE_BURN` (0x02).
- Different `intent_id` on same outpoint → different ν (intent-scoped; intentional for corridor lab).
- Different `vout` → different ν (multi-output safe once observation carries vout).
- **Provisional:** not a Tacit burn-set membership proof; under `mock_verify` membership is still self-asserted flags. Replacing this with true burn ν is a later crypto track — **do not amend D1–D7** here.

**Rejected alternatives (do not implement as SSOT):**
- MINT gap sketch that hashed `amount_sats` into ν (amount binds via `value_u64` + `claim_id`, not ν).
- Pure-film “ν = raw txid bytes / btc_txid_or_intent_id without domain tag” on chain path.
- Hinge label `nu-hinge-happy` on deposit-backed path.

```rust
pub type Hash32 = [u8; 32];

/// Pure: provisional deposit nullifier.
pub fn deposit_nullifier_v0(txid: &Hash32, vout: u32, intent_id: &str) -> Hash32 {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    h.update(TERP_BTC_DEPOSIT_NU_V0);
    h.update(txid);
    h.update(vout.to_be_bytes());
    h.update(intent_id.as_bytes());
    let d = h.finalize();
    let mut out = [0u8; 32];
    out.copy_from_slice(&d);
    out
}

/// Parse 64-hex (optional 0x) → Hash32; fail-closed on length/charset.
pub fn parse_txid32(txid_hex: &str) -> Result<Hash32, ClaimFromDepositError>;
```

### 2.2 Input DTOs (builder view — not necessarily CW-serde)

Builder may accept either hub types or thin views. Normative fields:

```rust
/// Observation fields required by the claim builder.
#[derive(Clone, Debug)]
pub struct DepositObservationView {
    pub intent_id: String,
    pub btc_deposit_addr: String,
    /// 64-char hex (reporter / hub).
    pub txid: String,
    /// Required for continuous identity. Hub extension: add to `DepositObservation`.
    pub vout: u32,
    pub amount_sats: u64,
    pub confirmations: u32,
    pub domain_bind: Option<String>,
    pub reporter: String,
}

/// Watch / preauth fields required by the claim builder.
#[derive(Clone, Debug)]
pub struct DepositWatchView {
    pub intent_id: String,
    pub btc_deposit_addr: String,
    /// Domain C intent bind string (display / optional echo check only).
    /// **Not** `BridgeMintClaimPublic.domain_binding` (Domain B — D2).
    pub domain_bind: String,
    /// 64-char hex (32B). Source of truth: G4 DEST-SEAL (golden/live).
    pub dest_owner_binding: String,
    pub min_amount_sats: u64,
    pub client_proof_digest: String,
}
```

### 2.3 Lab mint policy (labeled mock surface)

Roots/flags remain **lab-seeded**, not LC-fed. Honest label required in logs/receipts.

```rust
/// Corridor lab policy for non-deposit claim fields.
/// `lab_mock_membership = true` ⇒ claim flags `in_burn_set`/`in_pool_root` true.
/// Does **not** imply production membership (D7).
#[derive(Clone, Debug)]
pub struct CorridorLabMintPolicy {
    pub source_chain_tag: String,       // default: "bitcoin-regtest" on ict; "bitcoin-mainnet" only if asset registry matches
    pub tacit_asset_id: Hash32,         // lab label or registry pin
    pub unit_scale: u64,                // default 1; value_u64 = amount_sats * unit_scale (checked no overflow)
    pub dest_domain: Hash32,            // must match BridgeCfg.dest_domain on chain
    pub pool_domain: Hash32,
    pub source_pool_root: Hash32,       // must match ReflectionSnapshot when minting
    pub source_burn_root: Hash32,
    pub source_height: u64,
    pub src_chain_id: Hash32,
    pub dst_chain_id: Hash32,           // typically = dest_domain
    pub lc_client_id_hash: Hash32,      // 32B pin used in domain_binding re-derive
    pub lab_mock_membership: bool,      // true on ict_local_funded default
    /// Client-held opening; non-zero → rcm_flag=1 on NoteOutResult.
    pub rcm: Option<Hash32>,
    /// Dest leaf / cm public (client constructs; lab may seed label).
    pub cm_public: Hash32,
    /// Builder-side conf floor (optional; 0 = skip). Independent of contract K.
    pub min_confirmations: u32,
    /// When true (default for deposit-backed path), missing/empty vout is error.
    pub require_vout: bool,
}

impl CorridorLabMintPolicy {
    /// Seed roots/labels aligned with happy hinge **except** ν/value/dest
    /// which come from deposit. Used only when lab reflection is pre-set to match.
    pub fn corridor_lab_default() -> Self { /* labels documented in §2.5 */ }
}
```

**Default lab labels (implementers may match `happy_bridge_mint_world` roots so existing `configure_bridge_happy` snapshot still works while identity fields change):**

| Policy field | Lab default label / rule |
|--------------|--------------------------|
| `dest_domain` | `sha256("terp-chain-1")` (same as happy) |
| `tacit_asset_id` | `sha256("tacit-btc-etch-1")` (happy) **or** corridor-specific label if asset re-registered |
| `source_pool_root` / `spent` / `burn` | happy hinge roots if snapshot is happy; **must equal** on-chain snapshot |
| `source_height` | happy `100` if snapshot is happy |
| `src_chain_id` | `sha256("src-bitcoin-mainnet")` or regtest pin — **must match** domain_binding re-derive |
| `lc_client_id_hash` | `sha256("lc-client-reflection-0")` |
| `pool_domain` | `sha256("terp-pool-0")` |
| `lab_mock_membership` | `true` |
| `unit_scale` | `1` |
| `rcm` | client random preferred; lab may use deterministic `sha256("rcm-corridor-deposit-v0" ‖ intent_id)` |
| `cm_public` | client leaf; lab may use `sha256("cm-leaf-deposit-v0" ‖ dest_commitment)` |

**Asset registry note:** contract re-derives claim_id with **`tacit_asset_id`** (not terp-mapped id) per current `authorize_bridge_mint_pure` — builder must match that SSOT (`bridge.rs` lines using `derive_claim_id_with_dest(..., &tacit, value)`).

### 2.4 Builder API (normative)

```rust
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ClaimFromDepositError {
    MissingTxid,
    InvalidTxidHex,
    MissingVout,
    MissingAmount,          // amount_sats == 0
    AmountBelowWatchMin,
    MissingDest,            // empty dest_owner_binding
    InvalidDestHex,         // not 32B after hex decode
    PlaceholderDest,        // optional product mode: reject "b"*64 / all-zero (G4 may own list)
    IntentMismatch,         // obs.intent_id != watch.intent_id
    AddrMismatch,           // obs.btc_deposit_addr != watch.btc_deposit_addr
    ConfirmationsBelowMin,
    ValueScaleOverflow,
    DomainBindEchoMismatch, // if both present and policy checks echo
}

/// Continuous identity builder. Pure: no chain, no HTTP.
///
/// - nullifier ← deposit_nullifier_v0(txid, vout, intent_id)
/// - value_u64 ← amount_sats * unit_scale
/// - dest_commitment = burn_dest_commitment ← decode(watch.dest_owner_binding)
/// - claim_id ← derive_claim_id_with_dest(dest_domain, dest_cm, nu, tacit, value)
/// - domain_binding ← derive_domain_binding(src, dst, lc, tacit, nu, height, burn_root)
/// - membership flags ← policy.lab_mock_membership (labeled lab)
pub fn claim_from_deposit_watch(
    obs: &DepositObservationView,
    watch: &DepositWatchView,
    policy: &CorridorLabMintPolicy,
) -> Result<BridgeMintClaimPublic, ClaimFromDepositError>;
```

**CosmWasm output type:** `cw_headstash::bridge::BridgeMintClaimPublic` (Binary fields).  
**Pure-first alternate:** implement with `Hash32` intermediate then `Binary::from` in test-press / bridge helper — preferred home: `test-press` harness helper **or** small pure module under fixtures / headstash bridge helpers (no CW rewrite required this round).

### 2.5 Field map (observation / watch / policy → claim)

| Source key | Source type | Claim field | Rule |
|------------|-------------|-------------|------|
| `txid` + `vout` + `intent_id` | obs + obs + obs/watch | `nullifier` | `deposit_nullifier_v0` |
| `amount_sats` | obs | `value_u64` | `amount_sats * unit_scale` (`unit_scale` default 1) |
| `dest_owner_binding` | watch (G4) | `dest_commitment`, `burn_dest_commitment` | hex → 32B; both equal |
| — | re-derive | `claim_id` | `derive_claim_id_with_dest` |
| policy roots | policy | `source_pool_root`, `source_burn_root`, `source_height` | must match chain snapshot |
| policy | policy | `dest_domain`, `pool_domain`, `tacit_asset_id`, `unit_scale` | lab pins |
| policy | policy | `src_chain_id`, `dst_chain_id`, `lc_client_id` | domain_binding inputs |
| — | re-derive | `domain_binding` | `derive_domain_binding` (Domain B) |
| `domain_bind` | watch/obs | **not a claim field** | Domain C; optional echo check only (D2 — do not merge into Domain B) |
| `btc_deposit_addr` | watch/obs | **not a claim field** | equality gate at builder; not on wire claim |
| `confirmations` | obs | builder gate only | optional `min_confirmations`; contract K still uses snapshot tip/source |
| policy.lab_mock_membership | policy | `in_burn_set`, `in_pool_root`, `spent_only` | true/true/false when lab mock |
| policy.rcm / cm_public | policy | `rcm`, `cm_public` | client-owned preferred |
| constant | policy | `source_chain_tag` | registry/asset map must accept |

### 2.6 Wire format / env / HTTP

#### Optional: GET claim-inputs (OBSERVE surface; sketch owned jointly)

```http
GET /corridor/claim-inputs/:intent_id
```

**Response JSON (hint-only; not mint authority):**

```json
{
  "intent_id": "string",
  "hint_only": true,
  "provisional_nullifier_domain": "terp-btc-deposit-nu-v0",
  "identity_status": "fields_ready | missing_watch | missing_observation | incomplete_fields",
  "watch": { "...DepositWatch" },
  "observation": {
    "intent_id": "...",
    "btc_deposit_addr": "...",
    "txid": "...",
    "vout": 0,
    "amount_sats": 20000,
    "confirmations": 1,
    "observed_at": 0,
    "reporter": "open_indexer",
    "domain_bind": null
  },
  "nullifier_preview_hex": "optional 64-hex when fields_ready",
  "dest_owner_binding": "echo watch field for harness",
  "amount_sats": 20000
}
```

**`identity_status`:**
- `fields_ready` — watch + observation present; txid non-empty; amount > 0; dest non-empty; vout present (after hub extension)
- `incomplete_fields` — present but missing txid/amount/dest/vout
- `missing_watch` / `missing_observation` — as named

Hub remains **hint bus** (D4). Host/UI re-verifies outpoint before trusting for product mint.

#### Observation extension (implement with claim-inputs)

```rust
// DepositObservation — add:
pub vout: u32,  // serde default 0 only for backward compat; builder require_vout=true rejects implicit zero unless explicitly allowed
```

Reporter already has `AddressFunding.vout` — post it through.

#### Env (harness consume — G3 implements; freeze names here)

| Env | Meaning |
|-----|---------|
| `CORRIDOR_CLAIM_INPUTS_URL` | optional override base for GET claim-inputs |
| `CORRIDOR_INTENT_ID` | intent to fetch |
| `CORRIDOR_ALLOW_HAPPY_FIXTURE` | if set, may fall back to hinge claim (mint-only residual); **default off** for deposit-backed bar |
| `CORRIDOR_MOCK_VERIFY` | existing; default true; label in logs |
| `CORRIDOR_DEPOSIT_VOUT` | optional override if hub not yet extended (lab only) |

---

## 3. File touch list (implementation order)

| Order | Path | Change |
|-------|------|--------|
| 1 | `crates/headstash/contracts/cw-headstash/src/bridge.rs` **or** `crates/headstash/test-press/src/harness/claim_from_deposit.rs` (prefer pure helper module) | Add `TERP_BTC_DEPOSIT_NU_V0`, `deposit_nullifier_v0`, `ClaimFromDepositError`, `CorridorLabMintPolicy`, `claim_from_deposit_watch`; unit tests. Prefer **not** bloating contract if Binary deps awkward — test-press + re-export is fine; pure fns must not need chain. |
| 2 | Optional pure fixture twin: `docs/plans/spectrum/fixtures/cashapp_zec_corridor` or new thin `deposit_claim_seams` | Same ν rule for film parity; keep domain tag identical. |
| 3 | `crates/terp-rs/tools/hash-market/src/corridor_deposits.rs` | Add `vout` to `DepositObservation`; validate on report; optional reject overwrite when txid differs. |
| 4 | `crates/terp-rs/tools/hash-market/src/btc_index/reporter.rs` | Pass `vout` from `AddressFunding` into observation POST body. |
| 5 | `crates/terp-rs/tools/hash-market/src/server.rs` | `GET /corridor/claim-inputs/:intent_id` → claim-inputs JSON; compute `nullifier_preview_hex` when ready. |
| 6 | `crates/headstash/test-press/src/harness/bridge_l1.rs` | `BridgeL1World::from_deposit_claim(claim, policy/snapshot/cfg)` constructor (claim identity from deposit; roots from policy/happy snapshot). |
| 7 | `crates/headstash/test-press/src/bin/corridor_ict_funded.rs` | (**G3 primary**) load claim-inputs / env → `claim_from_deposit_watch` → mint; fail-closed without `CORRIDOR_ALLOW_HAPPY_FIXTURE`. G1 only freezes interface. |
| 8 | `docs/plans/spectrum/e2e/corridor-ict-funded.sh` | After observe: curl claim-inputs; assert txid/amount; export env for mint binary. |
| 9 | Docs honesty (DOCS track residual) | USER-GUIDE: deposit-backed mint only when builder wired; still mock_verify. |

---

## 4. Acceptance tests (must be green to call done)

| ID | Layer | Command or assertion |
|----|-------|----------------------|
| **T1** | pure unit | `deposit_nullifier_v0` golden: fixed (txid, vout, intent_id) → fixed 32B hex; changing any input changes ν |
| **T2** | pure unit | Domain tag bytes exactly `b"terp-btc-deposit-nu-v0"` (length + content assert) |
| **T3** | pure unit | `claim_from_deposit_watch` happy: value_u64 == amount_sats * scale; dest == decode(dest_owner_binding); claim_id and domain_binding re-derive OK via `authorize_bridge_mint_pure` (or pure hinge) against matching snapshot |
| **T4** | pure unit | Fail-closed: empty txid → `MissingTxid` / `InvalidTxidHex` |
| **T5** | pure unit | Fail-closed: amount_sats == 0 → `MissingAmount` |
| **T6** | pure unit | Fail-closed: empty dest → `MissingDest` |
| **T7** | pure unit | Fail-closed: amount < watch.min_amount_sats → `AmountBelowWatchMin` |
| **T8** | pure unit | Fail-closed: intent_id mismatch obs vs watch → `IntentMismatch` |
| **T9** | pure unit | `require_vout=true` and builder path without explicit vout → `MissingVout` (or incomplete) |
| **T10** | pure unit | Double-mint identity: same inputs → same ν; second mint rejected by `BRIDGE_MINTED` when applied (unit or multi-test) |
| **T11** | hash-market lib | With features server: report observation with vout; GET claim-inputs → `identity_status=fields_ready`, amount/txid/vout/dest echo |
| **T12** | shell (funded, G3 joint) | After regtest fund: claim-inputs amount_sats equals bitcoind send; mint IsBridgeMinted(ν) for **deposit** ν not hinge ν; claim value == observed amount |

Suggested commands (implementers):

```bash
# pure / unit (crate depends on where helpers land)
cargo test -p zk-test-press claim_from_deposit -- --nocapture
# or
cargo test -p cw-headstash deposit_nullifier -- --nocapture

cargo test -p hash-market --lib corridor_deposits --features server
```

---

## 5. Fail-closed rules

| Condition | Expected error / exit |
|-----------|------------------------|
| Missing / empty `txid` | `ClaimFromDepositError::MissingTxid` — no claim built |
| `txid` not 32B hex | `InvalidTxidHex` |
| `require_vout` and vout absent / unspecified on product path | `MissingVout` |
| `amount_sats == 0` | `MissingAmount` (align dust reject) |
| `amount_sats < watch.min_amount_sats` (when min > 0) | `AmountBelowWatchMin` |
| Empty `dest_owner_binding` | `MissingDest` |
| Dest not 32B hex | `InvalidDestHex` |
| obs.intent_id ≠ watch.intent_id | `IntentMismatch` |
| obs.btc_deposit_addr ≠ watch.btc_deposit_addr | `AddrMismatch` |
| confirmations < policy.min_confirmations (if > 0) | `ConfirmationsBelowMin` |
| scale overflow | `ValueScaleOverflow` |
| Harness deposit-backed mode without claim-inputs / unmappable fields | process exit ≠ 0; **no** silent `BridgeL1World::happy()` |
| `CORRIDOR_ALLOW_HAPPY_FIXTURE` unset and fields incomplete | FAIL (do not mint fixture under “deposit-backed” label) |
| Domain C `domain_bind` used as Domain B `domain_binding` | Forbidden (D2); builder must re-derive Domain B only |

**Non-fail (labeled lab OK):**
- `lab_mock_membership=true` + non-empty mock proof under `mock_verify=true`
- Lab-seeded reflection roots (not LC) when explicitly configured to match claim
- Placeholder dest **may** still pass builder if G4 product reject not enabled; funded product path should enable G4 placeholder reject

---

## 6. Cross-track contracts

| Sibling | What this track needs from them | What this track promises |
|---------|--------------------------------|---------------------------|
| **G4 DEST-SEAL** | `dest_owner_binding`: 64-hex / 32B; golden primary on funded watch; document placeholder reject list | Copies binding into `dest_commitment` + `burn_dest_commitment` unchanged; never invents dest |
| **G2 NOTE-SWAP-SPEND** | (none to start design) | Mint note lineage: `nullifier_lineage` = deposit ν; `value` = observed amount; `owner_binding` = dest; openings via client `rcm` |
| **G3 HARNESS-SETTLE** | Will call builder + claim-inputs | Stable API: `claim_from_deposit_watch`, ν rule, env names, fail-closed without happy fixture |
| **OBSERVE (hub)** | `vout` on observation; claim-inputs GET | Field map + `identity_status` enum; nullifier preview domain string |
| **MINT contract** | Unchanged authorize / claim schema | Builder produces schema-valid `BridgeMintClaimPublic`; does not reopen claim shape |
| **UI** | — | May consume claim-inputs for display; still no bus mint authority |

### Dataflow target

```text
G4 dest_owner_binding ──┐
                        ├─► claim_from_deposit_watch ──► BridgeMintClaimPublic
obs(txid,vout,amount) ──┤              │
watch(intent,addr,min) ─┘              ▼
                              BridgeMintNote (G3) ──► NoteOutResult
                                    │
                                    ▼
                         G2 spends openings of that note
```

---

## 7. Explicit non-claims / residual after this track

- **Not** mainnet deposit claims or mainnet money.
- **Not** production burn membership / SP1 (`mock_verify=false` still residual under D7).
- **Not** LC-fed reflection tip (snapshot still owner-set lab).
- **Not** true Tacit BTC burn nullifier — provisional `terp-btc-deposit-nu-v0` only.
- **Not** harness shell green by design alone — G3 must wire execute.
- **Not** swap of minted note — G2.
- **Not** live ZEC egress.
- **Not** merging Domain C `domain_bind` into Domain B `domain_binding` (D2).
- **Not** amending D1–D7 freezes.
- Green `deposit_observed` alone still **≠** deposit-backed mint until builder + harness land.

---

## 8. Ready-for-impl checklist

- [x] Types named and field-complete (`deposit_nullifier_v0`, `claim_from_deposit_watch`, policy, errors, claim-inputs)
- [x] Touch list has owners (file paths)
- [x] Tests named T1–T12 (even if not written yet)
- [x] HANDOFF section updated (`## G1 IDENTITY-CLAIM`)
- [x] Fail-closed rules for missing txid/amount/dest
- [x] Exact domain string frozen: `terp-btc-deposit-nu-v0`
- [x] Lab mock flags labeled

---

## Appendix A — Worked example (normative sketch)

```text
intent_id        = "ict-demo-001"
txid_hex         = <32B hex from regtest send>
vout             = 0
amount_sats      = 20_000
dest_owner_binding = <G4 golden 64-hex>

ν = SHA256(b"terp-btc-deposit-nu-v0" ‖ txid32 ‖ 0x00000000 ‖ b"ict-demo-001")
value_u64 = 20_000
dest_commitment = decode(dest_owner_binding)
claim_id = derive_claim_id_with_dest(dest_domain, dest_commitment, ν, tacit, 20_000)
domain_binding = derive_domain_binding(src, dst, lc, tacit, ν, source_height, burn_root)
```

Assert after mint: `IsBridgeMinted(ν) == true` and event `NoteOutResult.value == 20_000` and `owner_binding == dest_commitment`.

## Appendix B — Conflict resolution note

STATUS-GAP-MINT §5 suggested hashing amount into ν. **Superseded for this epic** by synthesis Phase A1 + OBSERVE P0 + this design:

```text
nullifier = H("terp-btc-deposit-nu-v0" ‖ txid ‖ vout ‖ intent_id)
```

Amount binds through `value_u64` and `claim_id`, not ν.
