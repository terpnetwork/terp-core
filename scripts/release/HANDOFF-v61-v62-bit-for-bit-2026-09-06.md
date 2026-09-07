# Handoff — bit-for-bit recuration of v6.1 and v6.2 upgrade binaries

**Date:** 2026-09-06  
**Audience:** an objective teammate who did not cut these ELFs.  
**Goal:** From the git SHAs we communicate, rebuild `terpd` linux/amd64 and linux/arm64 and show the sha256 matches `networks/upgrades/{v6.1,v6.2}/ARTIFACT_LOCK`. That is how operators know the Cosmovisor binary is the source we named.

Do **not** upload S3 or broadcast gov. Heights stay TBD.

**Release control (v6.0.0 pattern):** ELF identity is git tag `v6.1.0` / `v6.2.0`. Pack files (`ARTIFACT_LOCK`, proposals) live on `release/v6.1.0` / `release/v6.2.0` and **must not move the tag**. Recurate checks out `binary_commit` (= the tag), not pack-branch HEAD. `terpd version` must print `6.1.0` / `6.2.0`, not a `-dev` or git-describe string.

---

## 1. What these two upgrades are

Two coordinated halts, two binaries, two Cosmovisor plan directories.

| Plan | Branch | Binary commit (ELF identity) | What the handler does |
|------|--------|------------------------------|------------------------|
| **v6.1** | tag `v6.1.0` / pack `release/v6.1.0` | `69b34350aec61681275d3bc8f985cb8456531dcc` | Upgrade A. `terpd version` = **6.1.0**. Pack files after this SHA live only on `release/v6.1.0`. |
| **v6.2** | tag `v6.2.0` / pack `release/v6.2.0` | `393ebd2fc0950fae4ff62e85946575820bf739f0` | Upgrade B. `terpd version` = **6.2.0**. Pack files after this SHA live only on `release/v6.2.0`. |

`x/upgrade` stores **one** plan. A dual gov tx can carry both messages; the last `ScheduleUpgrade` wins. The v6.1 handler re-arms v6.2 at `BlockHeight()+2`. Cosmovisor must pre-place **both** plan dirs.

Pack-only commits after those SHAs (proposal text, this handoff) **must not** be used as the ELF checkout. Recurate at `binary_commit` from the lock file.

---

## 2. Source pins the ELF must compile

`go.mod` replaces (both branches):

```
github.com/CosmWasm/wasmd => ./crates/zk-wasmd
github.com/CosmWasm/wasmvm/v3 => ./crates/zk-wasmvm
```

| Repo | SHA | Notes |
|------|-----|--------|
| terp-core v6.1 ELF | tag `v6.1.0` = `69b3435` | freeze source; pack is `release/v6.1.0` |
| terp-core v6.2 ELF | tag `v6.2.0` = `393ebd2` | freeze source; pack is `release/v6.2.0` |
| zk-wasmd | `5567942a` | nil-Ok including migrate; wasm-only reply |
| cosmwasm (packages/vm) | `d742487ff` | `used_internally_is_cache_oblivious` |
| zk-wasmvm | `93d4bce` | Path A only; C ABI lives on `feat/stwo-host-cgo-abci` |

Confirm:

```sh
git ls-tree HEAD crates/zk-wasmd crates/zk-wasmvm crates/cosmwasm
```

Muslc is **not** in git. Host must have STWO archives:

`crates/zk-wasmvm/internal/api/libwasmvm_muslc.aarch64.a`  
`crates/zk-wasmvm/internal/api/libwasmvm_muslc.x86_64.a`

Each must contain Path A STWO host (`grep -a -F 'stwo: Dummy DSTW rejected'`). There is no `verify_stwo_host_proof` C ABI on release wasmvm (that experiment is `feat/stwo-host-cgo-abci`). Expected sha256 of those `.a` files (cut host, until muslc is rebuilt without the C symbol):

```
0687e59140c967a752b0b0ede98e71a3c859fb4f6b94fc26883792d381eb4716  libwasmvm_muslc.aarch64.a
4f4880e1655d34c098729df52db22c9253bec87d2b3185669ff015a340b76d49  libwasmvm_muslc.x86_64.a
```

If your `.a` files differ, you are not compiling the same CGO waist.

`crates/ibc-hooks-v11` is gitignored. Recurate copies `HOOKS_SRC` (default that path) or fetches the pinned tarball (`scripts/ci/ibc-hooks-v11.sha256` = `1b31faa98bedb7e388eef97ed031143a851b0d8a799b52d7b1b3ab78c898a312`). Cosmovisor tarballs are packed with `pack_cv_tarball.py` (`SOURCE_DATE_EPOCH` = tag commit `%ct`: v6.1 `1788729561`, v6.2 `1788729565`). ELF sha256 is the consensus identity; tarball hashes are now reproducible under that packer.

---

## 3. Locked non-goals

- Not feemarket. Do not add Window.
- Do not set IAVL `DefaultOptions` hasher to BLAKE3 (hasher is the store/v2 patch).
- Do not register plan `v6.2` on the v6.1 binary.
- Do not `StoreUpgrades.Renamed` onto live `bank`/`staking`/`acc`.
- Do not use Docker tags `local` or `local-zk`.
- Do not invent S3 checksums. Lock `published: false` until upload is asked.
- Do not commit leftover zk-wasmd circuit-deposit or wasmvm ffi iterator with this cut.

---

## 4. How to recurate (the job)

Toolchain: Docker buildx, Go **1.26.5** via `golang:1.26.5-alpine` in `Dockerfile`, `WASMVM_SOURCE=local`.

From pack branch (has ARTIFACT_LOCK). Script checks out **tag / binary_commit**, not pack HEAD.

```sh
git fetch origin tag v6.1.0 tag v6.2.0
git fetch origin release/v6.1.0 release/v6.2.0
git checkout release/v6.2.0   # locks + recurate script
PLAN=v6.1 ./scripts/release/recurate_upgrade_binaries.sh
PLAN=v6.2 ./scripts/release/recurate_upgrade_binaries.sh
```

Build inside the worktree uses `RELEASE_TAG=v6.1.0` / `v6.2.0` so `terpd version` is exact.

The script fails closed if HEAD ≠ `binary_commit`, if the tree is dirty, if muslc lacks Path A STWO host, or if rebuilt sha256 ≠ lock.

Manual equivalent:

```sh
WASMVM_SOURCE=local make create-binaries
ALLOW_PARTIAL=1 PLAN=<plan> make release-prep RELEASE_TAG=<tag>
shasum -a 256 build/terpd-linux-amd64 build/terpd-linux-arm64
# compare to ARTIFACT_LOCK
```

Source archive (optional, tree identity):

```sh
git rev-parse HEAD^{tree}
git archive --format=tar HEAD | gzip -n -9 | shasum -a 256
```

That archive is the **git tree**, not the ELF. ELF identity is the lock sha256.

---

## 5. Expected checksums (cut host, 2026-09-06)

### v6.1 (tag `v6.1.0` = `69b3435`)

| File | sha256 |
|------|--------|
| `terpd-linux-amd64` | `c4cd06d95f38bef37401dadafb539570c4cc3dd59bb60b41601fe9f311f2105b` |
| `terpd-linux-arm64` | `63834b070a8b4613f183b33c86da737b643c64b4fea41f2080a86c59855a6094` |
| `terpd-6.1.0-linux-amd64.tar.gz` | `838e79432355cafac57b7038059d4c223f79189a7ee11c78f9eb933f7396efbe` |
| `terpd-6.1.0-linux-arm64.tar.gz` | `a0ca105079f49cff3c042a860a75cb67adbf17f0cb0af4979641a065ccca8b36` |

`terpd version` contains **6.1.0** and commit `69b3435…`. GNU BuildID amd64 `499197d1…` arm64 `65a8c30e…`.

### v6.2 (tag `v6.2.0` = `393ebd2`)

| File | sha256 |
|------|--------|
| `terpd-linux-amd64` | `7d57502bb13f5e84ca5b18d10ff7def1ab129407b217b39e8a139d42b5c5ae5c` |
| `terpd-linux-arm64` | `e9152c4650fa5d2cb18c2584eb0907d095131de464e98c62256fcd06672fa256` |
| `terpd-6.2.0-linux-amd64.tar.gz` | `612f351f8a4cd45d4bf5b41af92c9a2dece303d8bc664454c2a16aacbc87bb71` |
| `terpd-6.2.0-linux-arm64.tar.gz` | `e36c1ccb69a5cf6edac63eb9440274b8419d11b1e7ea050c0449d2cccd5232a9` |

`terpd version` contains **6.2.0** and commit `393ebd2…`. GNU BuildID amd64 `ed293cf0…` arm64 `8c7b13b4…`.

No darwin pin (Cosmovisor linux only). Independent recuration (2026-09-07) matched all four linux ELF hashes. Tarball hashes above are the python packer, not `tar -czf`.

Tarball **member name must be `terpd`**. Cosmovisor `DAEMON_NAME=terpd`.

---

## 6. Cosmovisor layout (both plans)

```
$DAEMON_HOME/cosmovisor/genesis/bin/terpd     # v6 (already on chain)
$DAEMON_HOME/cosmovisor/upgrades/v6.1/bin/terpd
$DAEMON_HOME/cosmovisor/upgrades/v6.2/bin/terpd
```

`DAEMON_ALLOW_DOWNLOAD_BINARIES=false` until S3 objects exist. `file://` is not a download URL.

Proposal JSON (expedited, height `0` until ops fill it):

- v6.1: `networks/upgrades/v6.1/draft_proposal.json`
- v6.2: `networks/upgrades/v6.2/draft_proposal.json`
- dual (one tx, two messages): `networks/upgrades/v6.2/dual_proposal.json`

---

## 7. What “pass” looks like

1. Clean checkout of each `binary_commit`.
2. `PLAN=v6.1` recurate prints `OK` for both linux ELFs and both linux tarballs.
3. `PLAN=v6.2` same.
4. `file build/terpd-linux-*` is statically linked; Path A STWO host string hits (`stwo: Dummy DSTW rejected`). `verify_stwo_host_proof` must **not** be a required C ABI.
5. You can explain, from `git show $COMMIT` + `go.mod` replaces + muslc sha256, why the ELF hash is that hash.

If hashes diverge: first check muslc sha256, Go image digest (`golang:1.26.5-alpine@sha256:0178a641fbb4858c5f1b48e34bdaabe0350a330a1b1149aabd498d0699ff5fb2`), dirty tree, and that you did not recurate a pack-only commit.

---

## 8. QMD

| Field | Value |
|-------|--------|
| **Title** | v6.1 + v6.2 bit-for-bit Cosmovisor recuration |
| **lex** | `binary_commit ARTIFACT_LOCK recurate WASMVM_SOURCE=local proof_instance_verify STWO_HOST_VERIFY` |
| **vec** | How do we prove the upgrade ELF is the git tree we published? |
| **Anti-claim** | Matching a Docker tag is not ELF recuration; S3 URLs are not checksums until objects exist |
