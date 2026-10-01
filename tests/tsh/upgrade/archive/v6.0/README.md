# Archived TSH — v6.0 (plan `v6`)

These scripts proved the **shipped** morocco-1 upgrade **5.2.0 → plan `v6`**
(bulk_memory CosmWasm VM + Cosmovisor). They are **not** the hasher two-step.

| Script | Historical claim |
|--------|------------------|
| `a.sh` | morocco-1 appstate, `terp-mainnet` → `UPGRADE "v6" NEEDED` → this-tree `terpd` applies |
| `b.sh` | Local genesis + expedited gov `software-upgrade` named `v6` |
| `c.sh` | Two local chains through `v6`, then Hermes + polytone |
| `d.sh` | Pre-v6 `cw_template` guest still queries/executes after the v6 VM |
| `e.sh` | Cosmovisor genesis `terp-mainnet` → `upgrades/v6` without a manual restart |

Defaults: `OLD_BIND=terp-mainnet`, `UPGRADE_VERSION=v6`.

## Do not

- Run these as `make tsh-upgrade` on `feat/6.3.0-dev`. That Make target is
  `v63.sh` (plans **`v6.3` then `v6.4`**).
- Treat a green `d.sh` here as dest-bank BLAKE3 or 08-wasm LC proof.
- Replay against a post-v6 snapshot with `terp-mainnet` (5.2.0 dies:
  `expected … got 0`).

Replay (historical only):

```sh
cd tests/tsh/upgrade/archive/v6.0
OLD_BIND=terp-mainnet NEW_BIND=terpd sh a.sh
```

Current gate: `make tsh-upgrade` → `tests/tsh/upgrade/v63.sh`.
Wasm guest survival across **this** two-step: `hasher_wasm.sh` inside `v63.sh`.
Operator pack: `networks/upgrades/v6.3/CURATE.md`.
