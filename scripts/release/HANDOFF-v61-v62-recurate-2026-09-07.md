# Handoff — bit-for-bit recuration of v6.1.0 and v6.2.0 (all Cosmovisor arches)

**Date:** 2026-09-07  
**Audience:** teammate who did not cut these binaries. Fresh clone. Do not reuse a dirty dev tree.  
**Goal:** Rebuild every **Cosmovisor** architecture we ship, for **both** tags, and match sha256 to `ARTIFACT_LOCK` and to the public S3 objects.

Do **not** retag. Do **not** broadcast gov. Heights stay TBD.

PRs: [#272](https://github.com/terpnetwork/terp-core/pull/272) (`feat/6.1.0-dev` → `main`), [#273](https://github.com/terpnetwork/terp-core/pull/273) (`feat/6.2.0-dev` → `feat/6.1.0-dev`).

---

## Architectures in scope

`make create-binaries` / `build-reproducible` is **linux only** (static muslc, Docker buildx):

| GOOS/GOARCH | Cosmovisor key | Locked? |
|-------------|----------------|---------|
| linux/amd64 | `linux/amd64` | yes — both tags |
| linux/arm64 | `linux/arm64` | yes — both tags |

There is **no** darwin (or windows) pin. Host `go build` on macOS uses `libwasmvmstatic_darwin.a` and is not the Cosmovisor download path. `plan.info` is linux-only. Do not put `*-darwin-arm64.tar.gz` in Cosmovisor JSON.

If you still want a **host darwin-arm64** operator binary, build it on a Mac from the **tag** with `RELEASE_TAG=v6.1.0` / `v6.2.0` and report the hash — it will not match a lock file because we never published one.

---

## Release control (do not skip)

ELF identity is the **annotated git tag**. Pack files (`ARTIFACT_LOCK`, proposals, this handoff) live on `release/vX.Y.Z` and may be **ahead** of the tag.

| What | SHA |
|------|-----|
| tag `v6.1.0` | `69b34350aec61681275d3bc8f985cb8456531dcc` |
| pack `release/v6.1.0` | ahead of the tag — **do not build this** |
| tag `v6.2.0` | `62dfd3167b2f44d54760d2368b58cdce2cedb2b2` |
| pack `release/v6.2.0` | ahead of the tag — **do not build this** |

`terpd version` must print **`6.1.0` / `6.2.0`**, not `-dev` or git-describe.

v6.1 binary **does** arm plan `v6.2` from EndBlocker at apply (`MaybeArmV62`).  
v6.2 binary **must not**: no `armed plan v6.2` string in the ELF.

---

## Fetch (origin is the source of truth)

```sh
git fetch origin tag v6.1.0 tag v6.2.0
git fetch origin release/v6.1.0 release/v6.2.0 feat/6.1.0-dev feat/6.2.0-dev
git checkout release/v6.2.0   # recurate script + both ARTIFACT_LOCK files
git rev-parse v6.1.0^{commit}   # 69b34350…
git rev-parse v6.2.0^{commit}   # 62dfd316…
```

Confirm you are **not** on pack HEAD when compiling. Recurate checks out `binary_commit` into a worktree.

---

## Pins the ELF must compile

`go.mod` replaces (both tags):

```
github.com/CosmWasm/wasmd => ./crates/zk-wasmd
github.com/CosmWasm/wasmvm/v3 => ./crates/zk-wasmvm
```

| Repo | SHA |
|------|-----|
| zk-wasmd | `5567942a` |
| cosmwasm | `d742487ff` |
| zk-wasmvm | `93d4bce` (Path A; no `verify_stwo_host_proof` C ABI) |

```sh
git ls-tree v6.1.0 crates/zk-wasmd crates/zk-wasmvm crates/cosmwasm
git ls-tree v6.2.0 crates/zk-wasmd crates/zk-wasmvm crates/cosmwasm
```

Muslc is **not** in git. Need both:

`crates/zk-wasmvm/internal/api/libwasmvm_muslc.aarch64.a`  
`crates/zk-wasmvm/internal/api/libwasmvm_muslc.x86_64.a`

Each must contain `stwo: Dummy DSTW rejected`. Expected:

```
0687e59140c967a752b0b0ede98e71a3c859fb4f6b94fc26883792d381eb4716  libwasmvm_muslc.aarch64.a
4f4880e1655d34c098729df52db22c9253bec87d2b3185669ff015a340b76d49  libwasmvm_muslc.x86_64.a
```

`ibc-hooks-v11` is git-locked on the **pack** branch (`crates/ibc-hooks-v11` + `scripts/ci/ibc-hooks-v11.tar.gz`, sha256 `1b31faa98bedb7e388eef97ed031143a851b0d8a799b52d7b1b3ab78c898a312`). Recurate copies it into the tagged worktree. Do not fetch a floating MinIO object (`IBC_HOOKS_ALLOW_FETCH` stays off).

Toolchain: Docker buildx, Go **1.26.5** (`golang:1.26.5-alpine` in `Dockerfile`), `WASMVM_SOURCE=local`.

Tarballs: `pack_cv_tarball.py` (not host `tar -czf`). Epoch = tag commit `%ct`:

- v6.1: `SOURCE_DATE_EPOCH=1788729561`
- v6.2: `SOURCE_DATE_EPOCH=1788744480`

---

## Recurate (the job)

From `release/v6.2.0` (has both locks + packer):

```sh
PLAN=v6.1 ./scripts/release/recurate_upgrade_binaries.sh
PLAN=v6.2 ./scripts/release/recurate_upgrade_binaries.sh
```

That rebuilds **linux/amd64 and linux/arm64** for each tag, packs with the pack-branch python tarball, and compares sha256 to `networks/upgrades/{v6.1,v6.2}/ARTIFACT_LOCK`.

Pass = `OK` on both ELFs and both tarballs, twice.

Manual (same result):

```sh
git worktree add --detach /tmp/terp-v610 v6.1.0
# copy muslc + ibc-hooks into that worktree (recurate does this)
cd /tmp/terp-v610
RELEASE_TAG=v6.1.0 WASMVM_SOURCE=local make create-binaries
# pack from the pack-branch scripts, not this worktree's old tar -czf:
SOURCE_DATE_EPOCH=1788729561 BUILD_DIR=/tmp/terp-v610/build \
  PLAN=v6.1 TAG=v6.1.0 bash /path/to/release-v6.2.0/scripts/release/prep.sh 6.1.0
```

Repeat for `v6.2.0` with epoch `1788744480`.

Also download S3 and compare (objects are live):

```sh
curl -fsSL -o /tmp/s3-61-amd64.tar.gz \
  https://s3.terp.network/releases/terp-core/v6.1.0/terpd-6.1.0-linux-amd64.tar.gz
# same for arm64, and v6.2.0 pair
shasum -a 256 /tmp/s3-*.tar.gz
```

---

## Expected checksums

### v6.1 — tag `v6.1.0` = `69b34350…`

`terpd version` = **6.1.0**, commit `69b3435…`. GNU BuildID amd64 `499197d1…` arm64 `65a8c30e…`.

| File | sha256 |
|------|--------|
| `terpd-linux-amd64` | `c4cd06d95f38bef37401dadafb539570c4cc3dd59bb60b41601fe9f311f2105b` |
| `terpd-linux-arm64` | `63834b070a8b4613f183b33c86da737b643c64b4fea41f2080a86c59855a6094` |
| `terpd-6.1.0-linux-amd64.tar.gz` | `838e79432355cafac57b7038059d4c223f79189a7ee11c78f9eb933f7396efbe` |
| `terpd-6.1.0-linux-arm64.tar.gz` | `a0ca105079f49cff3c042a860a75cb67adbf17f0cb0af4979641a065ccca8b36` |

S3: `https://s3.terp.network/releases/terp-core/v6.1.0/`

### v6.2 — tag `v6.2.0` = `62dfd316…`

`terpd version` = **6.2.0**, commit `62dfd31…`. GNU BuildID amd64 `af1fa10e…` arm64 `9b81fce8…`. **No** `armed plan v6.2` in `strings`.

| File | sha256 |
|------|--------|
| `terpd-linux-amd64` | `b87c8986c6aa50305b437a2ed87325346683fc493b65b28d99ac6c4c02bf6833` |
| `terpd-linux-arm64` | `18e652532b316134d94d9631fb7b622432726c01acdcb5adc1773e857d42f151` |
| `terpd-6.2.0-linux-amd64.tar.gz` | `4f85a408b805be7f02690873722734b45e09335178d4334b82c9aaff880cf7db` |
| `terpd-6.2.0-linux-arm64.tar.gz` | `2f0157b032e32ae1bf7a88f1f384f00a02a729cf148aacf602298394234ecac0` |

S3: `https://s3.terp.network/releases/terp-core/v6.2.0/`

Tarball member **must** be `terpd` (`DAEMON_NAME`). ELF sha256 is consensus identity; tarball hashes are reproducible under `pack_cv_tarball.py`.

---

## What “pass” looks like

1. Clean checkout of each **tag**, not pack HEAD.
2. `PLAN=v6.1` recurate: OK × 4 (2 ELFs + 2 tarballs).
3. `PLAN=v6.2` recurate: OK × 4.
4. S3 objects byte-match the rebuilt tarballs.
5. linux ELFs are statically linked; Path A STWO string hits; v6.2 ELF has no arm-followup log string.
6. You can explain the hash from tag + `go.mod` replaces + muslc sha256.

If hashes diverge: muslc sha256, Go image `golang:1.26.5-alpine`, dirty tree, packing with BSD `tar -czf` instead of `pack_cv_tarball.py`, or recurate of a pack-only commit.

---

## Cosmovisor (operators, not the recurate job)

```
$DAEMON_HOME/cosmovisor/upgrades/v6.1/bin/terpd
$DAEMON_HOME/cosmovisor/upgrades/v6.2/bin/terpd
```

Plan names are **`v6.1` / `v6.2`**, not `v6.1.0`. S3 URLs are live; download still needs `?checksum=sha256:…` from `cosmovisor.json`.

---

## Locked non-goals

- Not feemarket / Window.
- Do not set IAVL `DefaultOptions` hasher to BLAKE3.
- Do not `StoreUpgrades.Renamed` onto live `bank`/`staking`/`acc`.
- Do not use Docker tags `local` / `local-zk`.
- Do not invent checksums. Do not move tags `v6.1.0` / `v6.2.0`.
- Do not submit `dual_proposal.json` as written (last `ScheduleUpgrade` wins; v6.1 binary already arms v6.2).
