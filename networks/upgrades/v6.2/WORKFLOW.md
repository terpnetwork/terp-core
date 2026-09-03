# v6.2 upgrade ops (Upgrade B) — Cosmovisor + snapshot TSH

Plan **`v6.2`**. Binary is **`feat/6.2.0-dev`**. Do not register this plan on `feat/6.1.0-dev`.

`x/upgrade` stores **one** plan. A single gov tx may carry two `MsgSoftwareUpgrade`
messages (v6.1 at `H`, v6.2 at `H+2`); the last `ScheduleUpgrade` wins. The v6.1
handler therefore **re-arms v6.2 at `BlockHeight()+2`** after Upgrade A. Cosmovisor
pre-places both plan directories.

## Artifacts

```sh
# this worktree
ALLOW_PARTIAL=1 PLAN=v6.2 make release-prep RELEASE_TAG=v6.2.0-dev
WRITE=1 PLAN=v6.2 TAG=v6.2.0-dev bash scripts/release/preflight_upgrade.sh
# tarball member must be terpd (DAEMON_NAME)
```

Do not invent S3 checksums. Do not upload until asked. `file://` is not a download URL.

## TSH (morocco-1 pack after v6)

Pin `morocco-1_22911849_2026-09-02T03-49-50Z.tar.lz4`. Not pruned `22807932` / archive `22749033`.

```sh
# PATH: terpd-v6 (v6), terpd-v61 (feat/6.1.0-dev), terpd (this tree)
OLD_BIND=terpd-v6 V61_BIND=terpd-v61 SKIP_INSTALL=1 STATE_SYNC=0 \
  SNAPSHOT_URL='https://minio.terp.network/snapshots/mainnet/morocco-1/pruned/morocco-1_22911849_2026-09-02T03-49-50Z.tar.lz4' \
  make tsh-upgrade-v62-cv
```

Cosmovisor: `genesis` = v6, `upgrades/v6.1` = v6.1 binary, `upgrades/v6.2` = this binary.
`--pruning=everything` after B; bank queries must still work; live store keys must not include `b3-*`.

Do **not** `StoreUpgrades.Renamed` onto existing `bank`/`staking`/`acc` — IAVL errors
`initial version set to H, but found earlier version`. Dest trees drop because this
binary does not remount them; the first v6.2 commit omits them from `CommitInfo`.

## Do not

- Use plan name `v6` or a morocco-1 broadcast.
- Set IAVL `DefaultOptions` hasher to BLAKE3.
- Mount `b3-*` on this binary (`GenerateKeys` dropped them so restart after B is sound).
