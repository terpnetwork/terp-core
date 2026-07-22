# STATUS — IMPL G3 HARNESS-SETTLE

| Field | Value |
|-------|--------|
| **Track** | G3 HARNESS-SETTLE |
| **Date** | 2026-07-22 |
| **Agent** | IMPL-HARNESS-SETTLE (G3) |
| **Outcome** | **Landed** (unit + multi-test green; full Docker ict path documented, not agent-run) |

## What landed

### Contract interface

| Path | Change |
|------|--------|
| `crates/headstash/contracts/cw-private-dex/src/interface.rs` | **New** `CwPrivateDexContract` + `Uploadable` (`cw_private_dex` artifact) |
| `crates/headstash/contracts/cw-private-dex/src/lib.rs` | `#[cfg(feature = "interface")] pub mod interface` |
| `crates/headstash/contracts/cw-private-dex/Cargo.toml` | `interface = ["dep:cw-orch"]` |
| `crates/headstash/Cargo.toml` | workspace dep `cw-private-dex` |

### Harness / suite

| Path | Change |
|------|--------|
| `test-press/src/harness/mint_evidence.rs` | `MintEvidenceV0`, `SettleReceiptV0`, write/read, openings fail-closed |
| `test-press/src/harness/swap_statement_cw.rs` | `swap_action_public_to_cw`, `lab_mock_swap_proof`, `build_swap_spend_handoff_from_mint` (SEAM openings → statement; pool ν ≠ bridge) |
| `test-press/src/suites/private_dex.rs` | Upload/instantiate, CreatePool, SettleSwap, quote, post-settle asserts |
| `test-press/src/bin/corridor_ict_funded.rs` | Stages under `CORRIDOR_CHAIN_SETTLE=1`: evidence → dex deploy → pool → settle → receipt |
| `test-press/Cargo.toml` | Always depend `cw-private-dex`; `interface` enables `cw-private-dex/interface` |

### Shell / just

| Path | Change |
|------|--------|
| `docs/plans/spectrum/e2e/prepare-corridor-ict-wasm.sh` | Dual prepare when `CORRIDOR_PREPARE_PRIVATE_DEX=1` / `CORRIDOR_CHAIN_SETTLE=1` → `artifacts/cw_private_dex.wasm` |
| `docs/plans/spectrum/e2e/corridor-ict-funded.sh` | Preflight dual wasm; export receipt paths; assert `SettleReceiptV0` when settle on |
| `crates/headstash/justfile` | `prepare-corridor-ict-wasm-settle`, `demo-corridor-ict-settle`, `demo-corridor-ict-settle-mint-only` |

## Env / labels

| Env | Role |
|-----|------|
| `CORRIDOR_CHAIN_SETTLE=1` | Enable G3 path |
| `CORRIDOR_MOCK_VERIFY` | Bridge **and** dex mock_verify (default true → `proof_mode=mock_verify_lab`) |
| `CORRIDOR_SKIP_SWAP_FILM` | Pure film only — **never** skips settle |
| `CORRIDOR_RUN_SWAP_FILM=1` | When settle on, also run pure W0–W7 residual |
| `CORRIDOR_MINT_EVIDENCE_PATH` | default `/tmp/corridor-mint-evidence.json` |
| `CORRIDOR_SETTLE_RECEIPT_PATH` | default `/tmp/corridor-settle-receipt.json` |
| `CORRIDOR_ALLOW_SETTLE_WITHOUT_MINT` | **Hard FAIL** if set |

Honesty: `halo2_swap=false`, `skip_ibc_post_swap=false` always in receipt; logs print `mock_verify_lab`.

## Tests run (agent)

```sh
cd crates/headstash
cargo test -p cw-private-dex
# → 11 passed

cargo test -p zk-test-press --features 'interface,l0-seams' --lib -- \
  mint_evidence swap_statement_cw private_dex empty_proof
# → 8 passed (openings fail-closed, map equality, settle_after_mint_mock, empty proof)

cargo check -p zk-test-press --bin corridor_ict_funded --features 'ict-daemon,l0-seams'
# → ok
```

| ID | Result |
|----|--------|
| T1 contract multitest | **green** |
| T2 pure map | **green** (`map_public_fields_equal`) |
| T3 L1 Mock settle | **green** (`settle_after_mint_mock`) |
| T4 openings missing | **green** |
| T5 empty proof | **green** |
| T6 missing wasm | coded in binary (FAIL closed message) |
| T7 full Docker ict settle | **not run by agent** (heavy; path below) |
| T8 soft-skip ban | shell `\|\| fail` + binary settle errors exit 1 |
| T9 receipt fields | serde + shell python assert when settle on |
| T10 labels | receipt + println |

## Docker path (human)

Requires: Docker, `terpnetwork/terp-core:local-zk` (or env image/tag), binaryen ≥120 for wasm-opt preferred.

```sh
cd crates/headstash
just prepare-corridor-ict-wasm-settle
# mint + settle only (no regtest):
just demo-corridor-ict-settle-mint-only
# full observe + mint + settle:
just demo-corridor-ict-settle
# inspect:
cat /tmp/corridor-settle-receipt.json
# expect status=complete, proof_mode=mock_verify_lab, private_dex_contract set
```

## Residuals / out of scope (unchanged)

- Halo2 swap circuit / real `proof_instance_verify` as funded default
- Skip / IBC-hooks / `post_swap` Action
- Live ZEC egress
- Continuous deposit→claim alone (G1); settle lab still uses fixture mint openings when evidence filled
- Automation host PUT of settle receipt (file written; host wiring optional)
- Pure film dual noise until settle becomes default green on `demo-corridor-ict`

## Cross-track

- **G2:** handoff builder uses `private_dex_seams::build_swap_action_from_seam_notes` + CW map; G2 thin wrappers in `compose_l0` can replace call site later without changing settle stage.
- **G1/G4:** mint evidence carries client openings; dest seal path independent.
