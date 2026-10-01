# Upgrade TSH

## Current gate — v6.3 then v6.4

Hasher two-step. Cosmovisor plan dirs **`v6.3`** and **`v6.4`**.

```sh
make tsh-upgrade          # morocco-1 pruned pack + in-place-testnet → v6.3 → v6.4
ALLOW_LOCAL_GENESIS=1 make tsh-upgrade-v63   # local three-ELF genesis instead
```

Local genesis, three ELFs from this tree (`terpd-v63pre` / `terpd-v63` / `terpd-v64`).
After A: dest bank ICS-23 is BLAKE3, `ibc` is SHA-256. After B: keepers on dest;
`debug hasher-proof --all` requires dest IAVL inner nodes BLAKE3 (bank, staking, acc, wasm, …)
and IBC SHA-256; `hasher_state.sh` re-queries module params/balances/validators/wasm codes,
then a bank send must land. `cw_template` still executes; counterparty `08-wasm-0`
VerifyMembership of dest-bank. Empty dest trees (no keys on local genesis) are skipped,
not treated as SHA-256.

`a.sh`, `d.sh`, `e.sh` exec `v63.sh`. Bodies that targeted plan **`v6`** are in
[`archive/v6.0/`](archive/v6.0/README.md).

## Shipped replays (not this cut)

| Target | Script | Claim |
|--------|--------|-------|
| `make tsh-upgrade-v61` | `v61.sh` | morocco-1 pack → plan `v6.1` |
| `make tsh-upgrade-v62-cv` | `v62-cv.sh` | Cosmovisor `v6.1` then `v6.2` |
| `make tsh-upgrade-v6-archive` | `archive/v6.0/a.sh` | 5.2.0 → plan `v6` |

Do not point v61 at pre-v6 packs (`22749033`, pruned `22807932`).

## 120u-1 soak (plan v6.1)

Not hasher. See `networks/upgrades/v6.1/WORKFLOW.md`.
