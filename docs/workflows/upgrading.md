# Upgrade Workflow

## TLDR

1. Prepare upgrade version + handler (`app/upgrades/<plan>`).
2. Unit-test the handler.
3. E2E / tsh: `make tsh-upgrade` (live fork), `make tsh-upgrade-wasm` (existing contracts), `make tsh-upgrade-cv` (Cosmovisor).
4. Prepare artifacts: binaries, checksums, Cosmovisor `binaries.json`, upgrade guide.
5. Expedited proposal on testnet, confirm halt + Cosmovisor swap.
6. Expedited proposal on mainnet.

v6 plan name is **`v6`** (not the git tag). Cosmovisor folder:

`~/.terpd/cosmovisor/upgrades/v6/bin/terpd`

## 1. Upgrade handler unit tests

See `app/upgrades/v6/upgrades_test.go`.

## 2. E2E / tsh

| Target | Script | What it proves |
|--------|--------|----------------|
| `make tsh-upgrade` | `tests/tsh/upgrade/a.sh` | Current mainnet binary loads appstate, hits `UPGRADE "v6" NEEDED`, new binary applies |
| `make tsh-upgrade` companion | `tests/tsh/upgrade/b.sh` | Fresh genesis + **expedited** gov software-upgrade |
| `make tsh-upgrade-wasm` | `tests/tsh/upgrade/d.sh` | Pre-v6 CosmWasm guest still executes after v6 |
| `make tsh-upgrade-cv` | `tests/tsh/upgrade/e.sh` | **Cosmovisor** swaps genesis → `upgrades/v6` without a manual restart |

## 3. Prepare upgrade assets

```sh
make create-binaries
make release-prep RELEASE_TAG=v6.0.0
make create-binaries-json RELEASE_TAG=v6.0.0
make create-upgrade-guide   # or:
python3 scripts/release/create_upgrade_guide/create_upgrade_guide.py \
  --type coordinated -c v5.2 -u v6 -t v6.0.0 -p <id> -b <height> \
  --out scripts/release/create_upgrade_guide/v5.2-to-v6.md
./scripts/release/create_proposal/submit_proposal.sh --height <H> --tag v6.0.0 --name v6
```

- Cosmovisor JSON: `make create-binaries-json`
- Checked-in guide template fill: `scripts/release/create_upgrade_guide/v5.2-to-v6.md`
- Expedited proposal JSON: `build/upgrade-proposal-v6.json`

## 4. Testnet then mainnet

Create proposal on testnet first. Confirm Cosmovisor auto-restart. Then mainnet expedited proposal.
