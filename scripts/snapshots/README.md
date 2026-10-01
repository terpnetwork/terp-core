> **Handoff (fill on this host):** `scripts/snapshots/HANDOFF-pruned-pack-handshake.md` — pruned pack public GET + `mc stat` before `latest`. Handshake only.
>
> Historical permafrost inventory (open locally): `scripts/snapshots/historical-record.html` — one-file timeline of `/permafrost/TERP/snapshots` plus the 0–11411800 genesis archive. Gaps are full-block coverage, not app-state islands.

# Chain snapshot curation (groot2)

Epoch job for **morocco-1** on groot2. Testnet is out of scope until this path is green.

## Layout (bucket `snapshots`)

```
https://minio.terp.network/snapshots/mainnet/morocco-1/pruned/snapshot.json
https://minio.terp.network/snapshots/mainnet/morocco-1/archive/snapshot.json
```

Each file is stock omnibus JSON: `{ "chain_id", "snapshots": [urls], "latest" }`.
Oline reads `latest` or `url`. Shared `genesis.json` / `chain.json` / `scripts/` / `state.json` stay at the chain root.

## Epoch

1. Spawn `/storage/chain/snapshot-epoch/pruned-home`, statesync from the live hub, stop, upload `pruned/`.
2. `systemctl stop terpd-mainet`, rsync **`data/` + `wasm/` only** into that home, `systemctl start terpd-mainet`.
3. Upload `archive/` from the copy while live is already running.

Live config (peer set, node_key, priv_validator, addrbook, keyring) is never copied.

**WASM cache:** do **not** ship `wasm/cache/` (Wasmer compile cache; ~650–700MiB on the hub). It is local to CPU + libwasmvm version. A mismatch is a one-tx gas error then apphash (BlockPro, ~23150894, v6.0.1, snapshot-synced). Pack `data/` + `wasm/state` + `wasm/wasm`. Operators: empty `wasm/cache` on first start (or after wasmvm bump): stop, `mv wasm/cache wasm-cache-backup`, `mkdir wasm/cache`, start. One-block `terpd rollback` only if already stuck.

**Cosmovisor:** the live unit may be `cosmovisor run start` (one instance). This script does **not** start a second Cosmovisor for the ephemeral pruned node. It copies `cosmovisor/current/bin/<DAEMON_NAME>` if that symlink exists, otherwise the running `terpd` `/proc/<pid>/exe` for `--home $LIVE_HOME`, otherwise `LIVE_BIN`. The copy is `$EPOCH_ROOT/bin/terpd`. After an upgrade, Cosmovisor swaps live; the next epoch copies the new current binary.

## Run (groot2)

```bash
ssh groot2
# pruned pack only (handshake / oline consume) — does not halt live, does not touch archive/
CLASS=pruned /home/returniflost/abstract/terp-core/scripts/snapshots/curate-epoch.sh
# weekly-style archive (halts LOCAL hub only — public Akash sentries are not this unit)
# OLINE_DANGER_HALT_LIVE=1 CLASS=archive /home/returniflost/abstract/terp-core/scripts/snapshots/curate-epoch.sh
```

Write path: `mc` alias `usb2` → MinIO `:9000`. `DRY_RUN=1` skips halt and upload.

Retention: `KEEP_LAST=1` — only the newest `pruned/*.tar.lz4` and newest `archive/*.tar.lz4`. Older class tars are deleted after each successful upload. Chain-root `genesis.json` / `chain.json` / `scripts/` / `state.json` are never pruned. Do not leave dated `*.tar.lz4` at the chain root.

Cron: daily **pruned** at 06:00 **PDT**. Weekly **archive** Sunday 07:00 PDT (opt-in hub halt). Do **not** wrap pruned cron in `flock` on `curate.lock` (script already locks).

```cron
0 6 * * * CLASS=pruned /home/returniflost/abstract/terp-core/scripts/snapshots/curate-epoch.sh >> /storage/chain/snapshot-epoch/logs/cron.log 2>&1
# Archive: brief stop of LOCAL hub only (terpd-mainet). Never oline/sentry dseqs.
# Sentries may flap host-rpc during the copy; they must not be restarted/remanifested.
0 7 * * 0 OLINE_DANGER_HALT_LIVE=1 CLASS=archive /home/returniflost/abstract/terp-core/scripts/snapshots/curate-epoch.sh >> /storage/chain/snapshot-epoch/logs/cron-archive.log 2>&1
```

Ephemeral teardown: `setsid` + kill process group + `pgrep --home $EPH_HOME` (never `$LIVE_HOME`). Spawn refuses if `:27657` is still bound (leftover temp node). EXIT trap reaps the temp node, restarts the hub if this job halted it, and **deletes** `$EPH_HOME` so a failed archive rsync cannot leave a ~100GiB tree (2026-09-13). `CLASS=reap-only` is the same reap+delete without packing.

`ensure_live` must not swallow `q upgrade` JSON failures (`set -euo pipefail` + jq on log-mixed stdout aborted 2026-09-14 with no `ERROR:` line). Archive `rsync` treats vanished-file **24** as retry, not success-via-`set -e` abort; drain LevelDB LOCK after `systemctl stop` before copy.
