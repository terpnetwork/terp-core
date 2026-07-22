# Epic — Design-prep: connect private swaps (gaps 1–4)

| Field | Value |
|-------|--------|
| **Date** | 2026-07-22 |
| **Board** | `private-bridge-corridor` |
| **Mode** | **Design review / impl-ready pack** — read codebase, freeze interfaces, acceptance tests, file touch lists. **No large product implementation** in this round (stubs OK only if needed to validate a type/signature). |
| **Prior synthesis** | `btc-terp-zec-full-e2e-prep-2026-07-22/STATUS-GAP-SYNTHESIS.md` |
| **New settle surface** | `crates/headstash/contracts/cw-private-dex` + `STATUS-CW-PRIVATE-DEX-2026-07-22.md` |
| **North star (honest)** | Continuous local multi-net: deposit identity → mint SEAM → spend that SEAM (pure then CW settle) → dest seal holds. **Not** mainnet; **not** live ZEC egress as exit criterion of this epic. |

## Gaps assigned (from product session)

| ID | Gap | Track | Owner phase (synthesis) |
|----|-----|-------|-------------------------|
| **G1** | Continuous deposit identity → `BridgeMintClaimPublic` | **IDENTITY-CLAIM** | Phase A |
| **G2** | Minted SEAM → swap spend openings (no synthetic `NoteIn`) | **NOTE-SWAP-SPEND** | Phase D (depends G1 outputs) |
| **G3** | Wire funded harness → `cw-private-dex` `SettleSwap` | **HARNESS-SETTLE** | Phase E (depends G2 shape) |
| **G4** | Dest seal: golden/live `dest_owner_binding` on funded path | **DEST-SEAL** | Phase B4 |

## Parallelism rules

```text
G1 ═══════════════════════════════════════════► (IDENTITY-CLAIM)
G2 ═══════════════════════════════════════════► (NOTE-SWAP-SPEND)  // design against G1 handoff types even if G1 not coded
G3 ═══════════════════════════════════════════► (HARNESS-SETTLE)  // design against G2 settle statement + mint evidence
G4 ═══════════════════════════════════════════► (DEST-SEAL)       // parallel; dest is input to G1 claim dest field
```

- All four **design packs** ship in parallel.
- **Implementation** later: G1 + G4 first for continuous mint, then G2 pure, then G3 chain settle.
- Tracks must **freeze cross-track interfaces** in `HANDOFF.md` so implementers do not thrash.

## Deliverable per track

Write under this folder:

1. `DESIGN-<TRACK>.md` — required structure (PROMPT-COMMON)
2. Update `HANDOFF.md` section for this track (or append)
3. Optional: pure sketch types only if they fit existing fixtures (no CW rewrite in this round unless trivial)

## Explicit non-goals (this epic)

- Halo2 swap circuit  
- Skip/IBC-hooks post-swap Action wiring (follow-on after G3 settle solid)  
- Live ZEC broadcast / mainnet  
- Amending D1–D7 freezes  
- SP1 / `mock_verify=false` as P0  

## SSOT reads (all tracks)

- `STATUS-GAP-SYNTHESIS.md` (Phases A–F)  
- `STATUS-CW-PRIVATE-DEX-2026-07-22.md`  
- `crates/headstash/contracts/cw-private-dex/README.md`  
- `docs/plans/spectrum/fixtures/private_dex_seams`  
- `docs/plans/spectrum/fixtures/compose_seams`  
- `crates/headstash/contracts/cw-headstash/src/bridge.rs`  
- `docs/plans/spectrum/e2e/corridor-ict-funded.sh`  
- `crates/headstash/test-press/src/bin/corridor_ict_funded.rs`  
- `crates/headstash/test-press/src/harness/cashapp_zec_corridor.rs`  
