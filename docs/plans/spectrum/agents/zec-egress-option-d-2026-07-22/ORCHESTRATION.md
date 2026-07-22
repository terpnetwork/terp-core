# Epic — ZEC egress Option D (private bridge)

| Field | Value |
|-------|--------|
| **Date** | 2026-07-22 |
| **Decision** | `DESIGN-DECISIONS-ZEC-EGRESS-OPTION-D-ACCEPTED-2026-07-22.md` (**LOCKED**) |
| **Mode** | Design freeze + **immediate implementation** |
| **North star** | After `SettleSwap` ZEC-SEAM: **burn on Terp → Zcash mint/pay to preauth dest only** |
| **Prior** | G1–G4 connect-private-swap pack |

## Tracks (parallel)

| Track | Owns | Deliverable |
|-------|------|-------------|
| **PURE-EGRESS** | Pure types + apply_egress_burn + dest equality + ν domains | fixture + tests |
| **CW-EGRESS** | CosmWasm burn/egress execute (headstash or private-dex) + mock dual-path | contract + multitest |
| **ZAKURA-PAY** | Lab Zcash pay to sealed dest **only after** burn evidence | harness + optional RPC |
| **HARNESS-D** | Wire settle → egress burn → zec pay → receipt | corridor binary/shell |
| **META** | STATUS synthesis + honesty bars | STATUS-EPIC |

## Constraints

- Dest: transparent **or** shielded UA — both OK; seal fixed at intent (G4)
- No product host-pay without burn evidence
- No Skip/unshield as product path
- Lab mock_verify OK if labeled
- Prefer in-tree: headstash, private_dex_seams, compose_seams, zakura_local, corridor e2e

## SSOT reads

- ACCEPTED decision (parent `docs/plans/spectrum/`)
- `HANDOFF.md` (this folder)
- `DESIGN-ZEC-EGRESS-D.md`
- G3 settle receipt / mint evidence types
- `cw-headstash` bridge mint (mirror burn surface)
- `cw-private-dex` SettleSwap
