# DESIGN-DEST-SEAL

## 0. Track charter

| Field | Value |
|-------|--------|
| **Goal (one sentence)** | Freeze golden/live `dest_owner_binding` as the only allowed funded-path dest seal, with equality asserts and fail-closed rejection of empty/placeholder invents. |
| **Closes gap ID** | **G4** (synthesis Z-G3 / Phase B4; partial Z-G4 film continuity) |
| **Depends on handoffs** | None for design; offline golden already certified. Optional live RPC when Zakura up. |
| **Produces handoffs** | Normative `SealedDestV0` + SSOT paths; watch/open field contract; placeholder reject rules; equality surface for G1 claim `dest_commitment` / G2–G3 owner_binding narrative. |

---

## 1. Current code reality (cite paths)

| Surface | Status | Path / command |
|---------|--------|----------------|
| Golden SSOT file | **Green** | `docs/plans/spectrum/e2e/zakura/golden-dest-binding.json` — domain `terp-dest-binding-v0`; primary dest `tmJymvcUCn1ctbghvTJpXBwHiMEB8P6wxNV` → binding `8b5cac11e39905d56126a0c538b84ff8daa379d8009d4e8b121112479607f09b` |
| Shell parity | **Green** | `docs/plans/spectrum/e2e/zakura/zakura-local.sh` `golden` / `dest` |
| Harness digest | **Green** | `crates/headstash/test-press/src/harness/zakura_local.rs` — `owner_binding_from_dest_display`, `primary_golden_dest`, `REGTEST_MINER_*` |
| Pure W0–W7 golden | **Green (film)** | `cashapp_w0_w7_with_golden_primary_dest` in `zakura_local.rs` tests |
| UI helpers | **Green (lab)** | `websites/dao-dao-ui/.../PrivateCorridor/zakuraDest.ts` — `DEST_BINDING_DOMAIN`, `GOLDEN_OWNER_BINDING_HEX`, `destOwnerBindingHex`, `softValidateZecDest`, `localZakuraDemoDestOffline` |
| Just offline floor | **Green** | `crates/headstash/justfile` → `demo-zakura-local-dest` |
| Live RPC optional | **Scripted skip-clean** | `zakura_rpc_health_and_validate_when_available`; compose ports 18232/18233/19901 |
| Funded ICT watch open | **Placeholder** | `docs/plans/spectrum/e2e/corridor-ict-funded.sh` L150: `"dest_owner_binding": "b" * 64` |
| Lab smoke watch open | **Placeholder** | `docs/plans/spectrum/e2e/corridor-lab-smoke.sh` L58: `DEST="$(printf 'b%.0s' {1..64})"` |
| Funded swap film | **Uncoupled default** | `corridor_ict_funded.rs` uses `CorridorScenario::default()` → `hash_tag("dest-owner-cashapp-zec-demo")` — **not** golden |
| Hash-market open_watch | **Empty-only gate** | `crates/terp-rs/tools/hash-market/src/corridor_deposits.rs` rejects empty dest; **does not** reject `"b"*64` |
| Unit sample watch | **Uses placeholder** | same file tests: `dest_owner_binding: "b".repeat(64)` (unit only; not product path) |
| Live ZEC broadcast | **Absent (non-goal)** | No `z_send*` / egress in this track |

```text
IMPLEMENTED:
  paste/golden dest_display ──► owner_binding (domain v0)   ✓ UI + shell + Rust
  offline golden parity + just floor                       ✓
  pure W0–W7 with golden binding                           ✓ film
  live validateaddress when RPC up                         ✓ optional skip

NOT IMPLEMENTED (this track's impl work):
  funded watch open uses golden/live binding               ✗ "b"*64
  corridor_ict_funded W0–W7 uses primary_golden_dest       ✗ default hash_tag
  product fail-closed on known placeholders                ✗ empty-only
  evidence log asserts receipt binding == sealed           ✗ missing on funded
```

---

## 2. Target interface (freeze)

### Types / APIs (normative for implementers)

```rust
/// Domain tag — MUST match UI `DEST_BINDING_DOMAIN` and golden JSON `domain`.
pub const DEST_BINDING_DOMAIN_PREFIX: &str = "terp-dest-binding-v0";

/// Primary corridor regtest miner dest (node-corridor.toml miner_address).
pub const REGTEST_MINER_DEST: &str = "tmJymvcUCn1ctbghvTJpXBwHiMEB8P6wxNV";

/// Primary golden owner_binding hex for REGTEST_MINER_DEST (lowercase, 64 chars).
pub const REGTEST_MINER_OWNER_BINDING_HEX: &str =
    "8b5cac11e39905d56126a0c538b84ff8daa379d8009d4e8b121112479607f09b";

/// Preimage: `terp-dest-binding-v0|` ‖ utf8_trim(dest_display) → SHA-256 → [u8; 32]
pub fn owner_binding_from_dest_display(dest_display: &str) -> [u8; 32];
pub fn owner_binding_hex(dest_display: &str) -> String; // lowercase hex, width 64

/// Sealed dest for funded path / G1 claim dest field.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SealedDestV0 {
    /// Operator/UI paste string (non-authoritative).
    pub dest_display: String,
    /// 32-byte seal — authoritative for watch, claim, mint owner, swap recheck, receipt.
    pub owner_binding: [u8; 32],
    /// Lowercase hex encoding of owner_binding; **width = 64**.
    pub owner_binding_hex: String,
    /// How the seal was obtained.
    pub source: SealedDestSource,
    pub rpc_ready: bool,
    pub rpc_validated: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SealedDestSource {
    /// Primary sample from golden-dest-binding.json (default funded offline).
    GoldenPrimary,
    /// Env override: ZAKURA_DEST_ADDR → digest (must pass soft validate + not placeholder).
    EnvOverride,
    /// Live: dest string + optional validateaddress when ZAKURA_RPC up.
    LiveRpc,
    /// UI paste path (product; same digest domain).
    UiPaste,
}

/// Resolve sealed dest for **product funded path** (never invent placeholder).
///
/// Order:
/// 1. If `ZAKURA_DEST_ADDR` set → digest that (after reject_empty + reject_placeholder + soft prefix).
/// 2. Else → `primary_golden_dest()` from golden JSON / REGTEST_MINER_*.
/// 3. If RPC up (`ZAKURA_RPC`): optional `validateaddress`; set flags; **do not fail closed**
///    when RPC down (offline golden remains valid). Fail closed only when
///    `CORRIDOR_REQUIRE_ZAKURA_RPC=1` and RPC down / invalid.
pub fn seal_funded_dest(cfg: &ZakuraLocalConfig) -> Result<SealedDestV0, DestSealError>;

/// Known lab placeholders that must never ship on product funded path.
pub fn is_placeholder_owner_binding_hex(hex: &str) -> bool {
    let h = hex.trim().to_lowercase();
    h.is_empty()
        || h == "b".repeat(64)
        || h == "a".repeat(64) // domain_bind filler — not a dest seal
        || h == "c".repeat(64)
        || h == "0".repeat(64)
        || h.chars().all(|c| c == 'b') && h.len() == 64
}

/// Fail-closed gates (product funded + claim handoff).
pub fn reject_empty_dest(dest_display: &str) -> Result<(), DestSealError>;
pub fn reject_placeholder_binding_hex(hex: &str) -> Result<(), DestSealError>;
pub fn require_binding_hex_width(hex: &str) -> Result<[u8; 32], DestSealError>; // exactly 64 hex chars → 32B

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DestSealError {
    EmptyDest,
    PlaceholderBinding(String),
    BadHexWidth { got: usize, want: usize },
    SoftValidateFailed(String),
    Golden(String),
    RpcRequiredButDown(String),
    RpcInvalidAddress(String),
    BindingMismatch { left: String, right: String, surface: String },
}
```

**Equality helper (shared by G1 / G4 evidence):**

```rust
/// Assert continuous dest identity across surfaces (hex, lowercase, 64).
pub fn assert_dest_binding_equal(
    sealed_hex: &str,
    other_hex: &str,
    surface: &str, // e.g. "watch", "claim.dest_commitment", "mint.owner_binding", "receipt"
) -> Result<(), DestSealError>;
```

### Wire format / env vars / HTTP

| Item | Normative value |
|------|-----------------|
| **Watch / OpenWatch field name** | `dest_owner_binding` |
| **Wire type** | JSON string |
| **Width** | **64** lowercase hex characters = **32 bytes** |
| **Semantic** | Domain-separated SHA-256 of dest display; **not** the raw UA/t-addr string |
| **DepositWatch field** | same name + width on stored watch |
| **Claim field (G1)** | `BridgeMintClaimPublic.dest_commitment` / `burn_dest_commitment` = **same 32 bytes** as sealed `owner_binding` (binary/base64 on-chain; hex on host) |
| **Note field (G2)** | `SeamNoteOutV0.owner_binding` / mint note `owner_binding` = same 32 bytes |
| **Receipt field** | `CorridorReceiptV0.dest_owner_binding_hex` = lowercase hex of same |

| Env | Role | Default |
|-----|------|---------|
| `ZAKURA_GOLDEN_DEST_BINDING` | Path override for golden JSON | monorepo `docs/plans/spectrum/e2e/zakura/golden-dest-binding.json` |
| `ZAKURA_DEST_ADDR` | Override dest_display (digest recomputed) | primary miner dest |
| `ZAKURA_RPC` | Live validate optional | `http://127.0.0.1:18232` |
| `CORRIDOR_REQUIRE_ZAKURA_RPC` | If `1`/`true`, fail when RPC down or validateaddress false | off (offline golden OK) |
| `CORRIDOR_DEST_OWNER_BINDING` | Optional pin: if set, must equal sealed hex or fail (no silent override invent) | unset |
| `NEXT_PUBLIC_ZAKURA_RPC` / `NEXT_PUBLIC_ZAKURA_DEMO_DEST` | UI only | paste-first offline |

**Shell export contract for funded script (after seal):**

```bash
export ZAKURA_DEST_DISPLAY="tmJymvcUCn1ctbghvTJpXBwHiMEB8P6wxNV"   # or override
export CORRIDOR_DEST_OWNER_BINDING="8b5cac11e39905d56126a0c538b84ff8daa379d8009d4e8b121112479607f09b"
export CORRIDOR_DEST_SEAL_SOURCE="golden_primary"  # | env_override | live_rpc
export CORRIDOR_DEST_RPC_READY="false"             # true when RPC up
```

**SSOT resolution order (funded path must not invent dest):**

1. **File SSOT:** `docs/plans/spectrum/e2e/zakura/golden-dest-binding.json` (primary sample).  
2. **Rust constants:** `REGTEST_MINER_DEST` / `REGTEST_MINER_OWNER_BINDING_HEX` must match primary sample (asserted by harness tests).  
3. **Shell:** `zakura-local.sh dest` / `golden` recompute same digest.  
4. **UI:** `GOLDEN_OWNER_BINDING_HEX` + `destOwnerBindingHex` same preimage.  
5. **Just:** `demo-zakura-local-dest` is the offline cert command; **not** replaced by inventing hex in funded script.

**Digest algorithm (frozen):**

```text
owner_binding = SHA-256( utf8("terp-dest-binding-v0") ‖ utf8("|") ‖ utf8(trim(dest_display)) )
owner_binding_hex = lowercase hex(owner_binding)   # len == 64
```

---

## 3. File touch list (implementation order)

| Order | Path | Change |
|-------|------|--------|
| 1 | `crates/headstash/test-press/src/harness/zakura_local.rs` | Add `SealedDestV0`, `is_placeholder_owner_binding_hex`, `reject_placeholder_binding_hex`, `seal_funded_dest`, `assert_dest_binding_equal`; re-export from `harness/mod.rs` |
| 2 | `docs/plans/spectrum/e2e/corridor-ict-funded.sh` | Before watch open: run `zakura-local.sh dest` (or python/sha256 golden primary); export `CORRIDOR_DEST_OWNER_BINDING` / `ZAKURA_DEST_DISPLAY`; set watch `dest_owner_binding` to sealed hex — **never** `"b"*64` |
| 3 | `crates/headstash/test-press/src/bin/corridor_ict_funded.rs` | Swap film: `CorridorScenario { dest_owner_binding: sealed.owner_binding, .. }`; print evidence `dest_owner_binding_hex`; fail if receipt ≠ sealed |
| 4 | `crates/terp-rs/tools/hash-market/src/corridor_deposits.rs` | Product `open_watch`: reject empty **and** placeholder hex when env `CORRIDOR_REJECT_PLACEHOLDER_DEST=1` **or** always on funded profile label; keep unit tests free to use fillers only under `#[cfg(test)]` helper that bypasses product gate if needed |
| 5 | `docs/plans/spectrum/e2e/corridor-lab-smoke.sh` | Prefer golden primary for smoke dest (or label residual “lab placeholder OK only if `CORRIDOR_ALLOW_PLACEHOLDER_DEST=1`”) — product ICT path never uses allow flag |
| 6 | `crates/headstash/justfile` | Optional: `demo-corridor-ict` evidence documents sealed dest; keep `demo-zakura-local-dest` as pure offline floor |
| 7 | G1 consumer (coord) | Claim builder copies sealed binding → `dest_commitment` (out of G4 code ownership; contract frozen in HANDOFF) |

**Do not touch this round (design only):** Halo2, live ZEC send, D1–D7 freezes, golden JSON sample values (already frozen).

---

## 4. Acceptance tests (must be green to call done)

| ID | Layer | Command or assertion |
|----|-------|----------------------|
| **T1** | pure | `cargo test -p zk-test-press --lib zakura_local --features 'interface,l0-seams' -- --nocapture` — golden + domain + offline dest |
| **T2** | pure | New: `seal_funded_dest` returns primary golden when env unset; `owner_binding_hex == REGTEST_MINER_OWNER_BINDING_HEX` |
| **T3** | pure | New: `reject_placeholder_binding_hex("b"*64)` errs; empty errs; zero hex errs |
| **T4** | pure | Existing: `cashapp_w0_w7_with_golden_primary_dest` — receipt hex == golden |
| **T5** | shell | `bash docs/plans/spectrum/e2e/zakura/zakura-local.sh golden` exit 0 |
| **T6** | shell | `bash docs/plans/spectrum/e2e/zakura/zakura-local.sh dest` prints `owner_binding=8b5cac11…` (when default dest) |
| **T7** | just | `cd crates/headstash && just demo-zakura-local-dest` exit 0 |
| **T8** | funded (impl) | After join: `corridor-ict-funded.sh` watch payload `dest_owner_binding` equals golden primary (or env digest); log line `dest_seal=…` present; **no** `"bbbbbbbb…"` |
| **T9** | funded (impl) | `corridor_ict_funded` swap film receipt `dest_owner_binding_hex` == sealed hex; exit non-zero on mismatch |
| **T10** | live optional | When `ZAKURA_RPC` up: `validateaddress` on dest_display; when down: skip-clean + `rpc_ready=false` (unless `CORRIDOR_REQUIRE_ZAKURA_RPC=1`) |
| **T11** | equality chain (with G1) | watch.dest_owner_binding == claim.dest_commitment_hex == mint.owner_binding_hex == receipt.dest_owner_binding_hex |
| **T12** | UI offline | Paste / “local Zakura demo dest” still produces `GOLDEN_OWNER_BINDING_HEX` without RPC |

---

## 5. Fail-closed rules

| Condition | Expected error / exit |
|-----------|------------------------|
| Empty `dest_display` / empty `dest_owner_binding` | `DestSealError::EmptyDest` / HTTP 4xx `"dest_owner_binding required"` / non-zero shell |
| Product funded path sets `"b"*64`, all-`b`, all-`0`, all-`a`/`c` fillers as dest seal | `DestSealError::PlaceholderBinding` — **reject**; do not open watch / do not mint |
| Hex length ≠ 64 or non-hex | `BadHexWidth` / parse error — reject |
| Soft prefix fail when dest_display provided for live/env override | `SoftValidateFailed` (lab demo handles `u1sim_*` still allowed) |
| `CORRIDOR_DEST_OWNER_BINDING` set but ≠ computed seal from dest_display | `BindingMismatch` — reject (no silent pin invent) |
| Watch dest ≠ claim dest_commitment (G1) | claim build / harness FAIL closed |
| Mint note owner_binding ≠ intent/watch dest | pure I1 / funded assert FAIL |
| Swap actual_owner_binding ≠ intent dest | `intent_allows_swap` REJECT (existing I1) |
| Receipt hex ≠ sealed | funded evidence stage exit 1 |
| `CORRIDOR_REQUIRE_ZAKURA_RPC=1` and RPC down or invalid address | non-zero; label error |
| RPC down and require flag **off** | **OK** — offline golden seal; `rpc_ready=false` in evidence |
| Inventing a fresh random dest on funded path without operator paste/env | **Forbidden** — must use golden primary or explicit `ZAKURA_DEST_ADDR` / UI paste |

**Honesty:** Fail-closed on placeholder ≠ requiring live ZEC broadcast. Offline golden paste remains a **valid** product seal for lab/funded film.

---

## 6. Cross-track contracts

| Sibling | What this track needs from them | What this track promises |
|---------|--------------------------------|--------------------------|
| **G1 IDENTITY-CLAIM** | Claim builder reads sealed 32B into `dest_commitment` / `burn_dest_commitment` without remapping hash | SSOT `SealedDestV0.owner_binding`; field name + width; equality assert helper |
| **G2 NOTE-SWAP-SPEND** | Spend path re-checks note `owner_binding` vs intent dest | Normative: dest seal bytes **are** the owner_binding narrative; no second domain |
| **G3 HARNESS-SETTLE** | Settle receipt / pool narrative may carry owner for open policy later | Funded harness joins seal **before** watch/mint; evidence prints sealed hex |
| **UI** | Continues paste-first; no exclusive Wizard rewrite this epic | Domain + golden constants stay shared; offline demo dest unchanged |
| **OBSERVE / hash-market** | Watch schema already has field | Product reject placeholder on funded open; store sealed hex as-is |

**Dataflow (target):**

```text
golden JSON / ZAKURA_DEST_ADDR / UI paste
        │
        ▼  owner_binding_from_dest_display
   SealedDestV0 { owner_binding, owner_binding_hex }
        │
        ├─► POST /corridor/watches.dest_owner_binding   (64 hex)
        ├─► G1 BridgeMintClaimPublic.dest_commitment    (32B)
        ├─► mint note / SeamNoteOut.owner_binding       (32B)
        ├─► G2/G3 swap recheck + receipt hex
        └─► evidence log (rpc_ready flags; no ZEC send claim)
```

---

## 7. Explicit non-claims / residual after this track

- **Not** live ZEC broadcast / `z_sendmany` / mainnet send (Phase F / Z-G1 residual).
- **Not** live receive/balance open proof on Zakura (Z-G2 residual).
- **Not** bare Zakura wallet UA mint (paste-first remains primary).
- **Not** full bech32m hard validate offline (soft prefix + optional RPC `validateaddress`).
- **Not** G1 claim builder implementation (only freezes dest bytes into claim).
- **Not** making `CorridorScenario::default()` golden for pure unit tests that intentionally use synthetic dest — **funded** path only must call `seal_funded_dest` / `primary_golden_dest`.
- **Not** amending D1–D7; D6 lab floor already accepted offline binding.
- **Not** equating W7 `status: complete` with ZEC chain settlement.

---

## 8. Ready-for-impl checklist

- [x] Types named and field-complete (`SealedDestV0`, placeholder reject, seal_funded_dest)
- [x] Touch list has owners (file paths)
- [x] Tests named (T1–T12; T8–T11 land with impl)
- [x] HANDOFF section updated (`## G4 DEST-SEAL`)
- [x] SSOT path frozen: `docs/plans/spectrum/e2e/zakura/golden-dest-binding.json`
- [x] Watch field: `dest_owner_binding`, width 64 hex / 32 bytes
- [x] Fail-closed: empty + placeholder; offline golden valid; no invent on funded path
- [x] Live ZEC broadcast **not** exit criterion
