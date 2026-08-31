# v6.1 upgrade ops (120u-1 testnet)

Chain **120u-1**. Plan name **`v6.1`**. This is not morocco-1 and not plan `v6`.

Do these in order. **Do not upload, tag, or broadcast** until asked.

1. **Checkout** `feat/6.1.0-dev`. Submodule `crates/zk-wasmd` must be the circuit-deposit SHA in `SOURCE_DEPS.txt`.

   ```sh
   git fetch origin && git checkout feat/6.1.0-dev
   git submodule update --init crates/zk-wasmd crates/zk-wasmvm
   ./scripts/release/curate_v61.sh
   ```

   That refreshes `SOURCE_DEPS.txt`, wasm checksums, and vendors patched `store/v2` locally (`HasherOptionForStore`). The vendor dir is gitignored; do not commit it.

2. **Compile** with ZK lineage (`WASMVM_SOURCE=local`, wasmd/wasmvm path replaces):

   ```sh
   GOWORK=off go install -mod=mod -tags "netgo ledger" -o "$HOME/go/bin/terpd-testnet-v61" ./cmd/terpd
   "$HOME/go/bin/terpd-testnet-v61" version
   ```

3. **Measure height** from the 120u-1 RPC `/status`. Fill `draft_proposal.json` `plan.height` (local soak: current + ~50). Leave proposal id unset. **Do not broadcast.**

4. **Stage** Cosmovisor. Plan directory name **must** be `v6.1`:

   ```sh
   mkdir -p "$DAEMON_HOME/cosmovisor/upgrades/v6.1/bin"
   cp "$HOME/go/bin/terpd-testnet-v61" "$DAEMON_HOME/cosmovisor/upgrades/v6.1/bin/terpd"
   chmod +x "$DAEMON_HOME/cosmovisor/upgrades/v6.1/bin/terpd"
   ```

   If the node is not started through Cosmovisor: wait for `UPGRADE "v6.1" NEEDED`, stop the old binary, start `terpd-testnet-v61 --home "$DAEMON_HOME"`.

5. **Submit** gov only when asked (`tests/tsh/upgrade/120u-1.sh` with `SUBMIT=1`). Then `terpd q upgrade applied v6.1`.

## What v6.1 does

- `RunMigrations` (SDK / IBC / wasm module versions).
- `CircuitUploadAccess = AllowNobody` (upload is ACL or circuit deposit).
- Copy `bank`/`staking`/`acc` → `b3-bank`/`b3-staking`/`b3-acc` (Upgrade A). IBC stays SHA-256.
- Does **not** re-add `hashmerchant` / `cw-hooks` if they already exist in genesis.
- Upgrade B (later) switches module keys and deletes the SHA-256 copies.

## Do not

- Use a morocco-1 height or plan name `v6`.
- Set IAVL `DefaultOptions` hasher to BLAKE3.
- Link stock CosmWasm muslc against ZK Go (`store_code_with_circuit`).
- Invent S3 checksums / upload / tag.
