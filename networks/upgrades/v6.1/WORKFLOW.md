# v6.1 upgrade ops (120u-1 testnet)

Chain **120u-1**. Plan name **`v6.1`**. This is not morocco-1 and not plan `v6`.

Do these in order. **Do not upload, tag, or broadcast** until asked.

1. **Checkout** `feat/6.1.0-dev`. Submodule `crates/zk-wasmd` must be the circuit-deposit SHA in `SOURCE_DEPS.txt`.

   ```sh
   git fetch origin && git checkout feat/6.1.0-dev
   git submodule update --init crates/zk-wasmd crates/zk-wasmvm
   ./scripts/release/curate_v61.sh
   ```

   That refreshes `SOURCE_DEPS.txt`, wasm + libwasmvm checksums, and vendors patched `store/v2` locally (`HasherOptionForStore`). The vendor dir is gitignored; do not commit it.

2. **Compile** the Cosmovisor tarball with ZK muslc (`WASMVM_SOURCE=local` is the Makefile default on this branch):

   ```sh
   make build-reproducible-amd64          # stages zk-deps + muslc, then muslc ELF
   ALLOW_PARTIAL=1 PLAN=v6.1 make release-prep RELEASE_TAG=v6.1.0-dev
   WRITE=1 make preflight-upgrade         # checksummed cosmovisor.json, never file://
   ```

   Host-native (not the soak ELF):

   ```sh
   GOWORK=off go build -mod=mod -tags "netgo ledger" -o "$HOME/go/bin/terpd-testnet-v61" ./cmd/terpd
   ```

   `go install -o` is not valid. Soak nodes must pre-place the **reproducible** `build/terpd-linux-amd64` (or unpack `build/terpd-6.1.0-dev-linux-amd64.tar.gz`, member `terpd`).

3. **Measure height** from the 120u-1 RPC `/status`. Fill `draft_proposal.json` `plan.height` (local soak: current + ~50). Leave proposal id unset. **Do not broadcast.**

   `plan.info` must be the compact Cosmovisor JSON from `cosmovisor.json` (`{"binaries":{…?checksum=sha256:…}}`). Preflight WRITE fills it from local tarball checksums. Those S3 URLs are the *intended* location; objects are not public until upload is asked. Until then set `DAEMON_ALLOW_DOWNLOAD_BINARIES=false` and pre-place.

4. **Stage** Cosmovisor. Plan directory name **must** be `v6.1`:

   ```sh
   mkdir -p "$DAEMON_HOME/cosmovisor/upgrades/v6.1/bin"
   cp build/terpd-linux-amd64 "$DAEMON_HOME/cosmovisor/upgrades/v6.1/bin/terpd"
   chmod +x "$DAEMON_HOME/cosmovisor/upgrades/v6.1/bin/terpd"
   ```

   If the genesis binary panics on `UPGRADE "v6.1" NEEDED` without exiting, point `current` at the plan and restart:

   ```sh
   ln -sfn "$DAEMON_HOME/cosmovisor/upgrades/v6.1" "$DAEMON_HOME/cosmovisor/current"
   ```

   Soak helper (bash, not sh): `SUBMIT=1 make tsh-upgrade-zero-cv`.

5. **Submit** gov only when asked (`tests/tsh/upgrade/120u-1.sh` with `SUBMIT=1`). Then `terpd q upgrade applied v6.1`.

## What v6.1 does

- Coordinated Cosmos SDK **v0.55.0** + CometBFT **v0.40.0** (this binary).
- `RunMigrations` (SDK staking 5→6 key-rotation fee, auth 6→7 ML-DSA gas, IBC / wasm).
- Copy leftover `x/params` subspace values (amino JSON) into tokenfactory, smartaccount, feeshare, and globalfee module stores, then wipe the subspace keys. The empty `params` store stays mounted this upgrade (SDK 0.55 cannot read it after delete). Unmount later. `protocolpool` is deleted.
- After apply, TSH `query-all-params.sh` (via `make tsh-upgrade-v61`) must query every module params without error.

OLD_BIND is **v6** (`terpd-v6`), never 5.2.0. `make tsh-upgrade-v61` curls `https://minio.terp.network/snapshots/mainnet/morocco-1/pruned/snapshot.json` `latest` (or pin `SNAPSHOT_URL`). Genesis is separate (`GENESIS_URL`). The tar is `data/` + `wasm/` only. Known-good pack: `morocco-1_22911849_2026-09-02T03-49-50Z.tar.lz4` (height 22911849 ≥ v6 halt 22810000). Do not use pruned `22807932` or archive `22749033` (pre-v6). A 5.2.0 load of the post-v6 pack dies (`expected 22911849 got 0`).
- `CircuitUploadAccess = AllowNobody` (upload is ACL or circuit deposit).
- Copy `bank`/`staking`/`acc` → `b3-bank`/`b3-staking`/`b3-acc` (Upgrade A). IBC stays SHA-256.
- Does **not** re-add `hashmerchant` / `cw-hooks` if they already exist in genesis.
- Upgrade B (later) switches module keys and deletes the SHA-256 copies.

## Do not

- Use a morocco-1 height or plan name `v6`.
- Set IAVL `DefaultOptions` hasher to BLAKE3.
- Link stock CosmWasm muslc against ZK Go (`store_code_with_circuit`).
- Put `file://` or a raw ELF path in `cosmovisor.json`.
- Invent S3 checksums / upload / tag.
