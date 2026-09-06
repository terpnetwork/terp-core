# Testnet 120u-1: v6.1

## Overview

Coordinated software upgrade on **120u-1**. Plan name **`v6.1`**. This is **not** morocco-1 / plan `v6`.

- **Plan name** (must match `app/upgrades/v6_1`): `v6.1`
- **Home**: `$DAEMON_HOME` (typically `~/.terpd-testnet`)
- **New binary**: built from `feat/6.1.0-dev` with `WASMVM_SOURCE=local`
- **Upgrade height**: fill from live `/status` + soak delta (see `WORKFLOW.md`). Placeholder in `draft_proposal.json` is **not** a scheduled halt.
- **Proposal**: not submitted

Includes: CosmWasm circuits (deposit runway, `CircuitUploadAccess=Nobody`), IAVL Upgrade A dual-store copy (`b3-*` dest trees; IBC SHA-256).

**Contract authors:** submessage **actions still happen**; `reply.events` no longer includes bank/`instantiate` plumbing. Audit list: [`CONTRACT-BREAKING.md`](./CONTRACT-BREAKING.md).

## Cosmovisor

Plan directory name **must** equal `v6.1`:

```sh
mkdir -p "$DAEMON_HOME/cosmovisor/upgrades/v6.1/bin"
cp "$(command -v terpd-testnet-v61)" "$DAEMON_HOME/cosmovisor/upgrades/v6.1/bin/terpd"
chmod +x "$DAEMON_HOME/cosmovisor/upgrades/v6.1/bin/terpd"
"$DAEMON_HOME/cosmovisor/upgrades/v6.1/bin/terpd" version
```

Manual (no Cosmovisor):

1. Wait for `UPGRADE "v6.1" NEEDED`.
2. Stop the pre-upgrade binary.
3. `terpd-testnet-v61 start --home "$DAEMON_HOME" --log_level info`.

## After halt

```sh
terpd-testnet-v61 q upgrade applied v6.1 --home "$DAEMON_HOME" --node "$NODE"
terpd-testnet-v61 q wasm params --home "$DAEMON_HOME" --node "$NODE"
# circuit_upload_access.permission must be Nobody
```

Logs should contain `v6.1: curated store` for bank/staking/acc and `v6.1: ibc/transfer/ica stores unchanged (sha256)`.
