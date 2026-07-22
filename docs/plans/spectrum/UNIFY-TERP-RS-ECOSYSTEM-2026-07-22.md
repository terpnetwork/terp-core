# Unification — move Private Bridge / spectrum out of grant into terp-rs ecosystem

| Field | Value |
|-------|--------|
| **Date** | 2026-07-22 |
| **Status** | **Checkpoint plan** — implement via follow-on PRs after local commits |
| **Goal** | Unify ecosystem tooling; retire grant-folder SSOT for product surfaces |

## Target homes

| Surface (today) | Target home | Notes |
|-----------------|-------------|--------|
| Corridor pure seams / fixtures under `docs/plans/spectrum/fixtures/*` | `crates/terp-rs/crates/` (e.g. `private-bridge-seams`, `compose-seams`) | Library crates, versioned with terp-rs workspace |
| hash-market observe / claim-inputs | already `terp-rs/tools/hash-market` | Keep; expand API only |
| `cw-headstash` bridge + egress (LC-adjacent mint/burn) | `terp-rs/contracts/` + **light-client** neighbors (`crates/crosslink/light-client`) | Bridge mint/egress stay next to LC hinge consumers |
| **`cw-private-dex`** | **`terp-rs/contracts/revenue/private-dex`** (or sibling under `revenue/`) | Revenue/DEX product family with auction / residual-registry |
| ict-rs Zakura / corridor spawn | stay `crates/ict-rs` (tooling) | Feature `zakura`; not grant docs |
| Spectrum design freezes / USER-GUIDE | `terp-rs/docs/` or `docs/product/private-bridge/` | Product docs, not grant proposal drafts |
| Grant-only narrative | archive under `docs/grant/` | Historical; no longer SSOT for code layout |

## Layout sketch (target)

```text
crates/terp-rs/
  crates/
    private-bridge-seams/     # pure apply_swap / egress / claim_from_deposit
    crosslink/light-client/   # LC hinge (existing)
  tools/
    hash-market/              # watches, claim-inputs, reporter
  contracts/
    revenue/
      auction/
      residual-registry/
      private-dex/            # ← cw-private-dex product home
    private-bridge/           # optional: cw-headstash bridge router slice
  docs/
    private-bridge/           # freezes + USER-GUIDE product copy
```

## Migration rules

1. **Do not** break headstash workspace mid-flight — symlink or path-dep first, then move.
2. Private dex **revenue** package owns CosmWasm settle product; headstash remains mint/egress router until split PR.
3. Light-client packages own **proof of foreign state**; contracts only call host `proof_instance_verify` / LC queries.
4. Grant folder becomes **read-only archive** after product docs live under terp-rs.

## Checkpoint commits (this session)

Local-only commits in:

- `crates/headstash` — private mint/swap/egress/harness
- `crates/ict-rs` — `feature=zakura`
- `terp-core` (docs) — spectrum freezes + e2e preflight + unify plan

**Not pushed.** Physical moves are follow-on.

## Out of this checkpoint

- Mainnet deploys  
- Renaming git remotes  
- Deleting grant history  
