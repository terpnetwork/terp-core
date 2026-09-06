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
| **v6.1** | `feat/6.1.0-dev` | `240e1f7c3420f09153c9bc8733ec15db1a9799d0` | Upgrade A: copy migratable IAVL → `b3-*`. HashMerchant consensus **2**, sudo cap **100663296**. CosmWasm halt/gas isolation. wasmvm pin **93d4bce** (no `verify_stwo_host_proof` C ABI). IBC stays SHA-256. |
| **v6.2** | `feat/6.2.0-dev` | `ca3f7ac8ed0c6027cfd6683f29db94b9b53ad218` | Upgrade B: keepers stay `bank`/`staking`/`acc`; unmounted `b3-*` dest trees drop from CommitInfo. Same CosmWasm pins as v6.1. IBC stays SHA-256. |

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
| terp-core v6.1 ELF | `240e1f7` | sound-hash + wasmvm without host C ABI |
| terp-core v6.2 ELF | `ca3f7ac` | Upgrade B + same wasmvm pin |
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

From a clone that has both branches and the recurate script (tip of `feat/6.2.0-dev` after this handoff). The script checks out `binary_commit` in a throwaway worktree; you do not recurate from a pack-only commit.

```sh
git fetch origin feat/6.1.0-dev feat/6.2.0-dev
git checkout feat/6.2.0-dev
# STWO muslc already in crates/zk-wasmvm/internal/api/ (or set MUSLC_SRC)
PLAN=v6.1 ./scripts/release/recurate_upgrade_binaries.sh
PLAN=v6.2 ./scripts/release/recurate_upgrade_binaries.sh
```

v6.1 lock file is on `feat/6.1.0-dev` (pack commit after `240e1f7`). ELF identity remains `240e1f7`. v6.2 ELF identity remains `ca3f7ac`.

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

### v6.1 (`240e1f7`)

| File | sha256 |
|------|--------|
| `terpd-linux-amd64` | `c11af8d8bdf1a8fe51a9ab8241c59d30b6c110fba96e8c8f8d2b5b2c09418160` |
| `terpd-linux-arm64` | `c9f7ef4e096a2ab48f2fce2b6c8c5783934feef28f666b56ee60a52e06c3a45f` |
| `terpd-6.1.0-dev-linux-amd64.tar.gz` | `663c15949182cac66459ad5f45d5d0a612a78d829d9cd1e77ecfee62bd21db87` |
| `terpd-6.1.0-dev-linux-arm64.tar.gz` | `1b027568836bb6fa172b8d3ebf43d24db3c1485572507c321c307b066b1988d5` |

GNU BuildID (amd64): `d805714b8475db0037000805388730bbee291e29`  
GNU BuildID (arm64): `9925d55cd0273719d4933eda4c1871c52c7f3e49`

### v6.2 (`ca3f7ac`)

| File | sha256 |
|------|--------|
| `terpd-linux-amd64` | `2cc658ae71fc0efd78eb31ae75e025694b80627b3ad445ce2bf8232099639388` |
| `terpd-linux-arm64` | `7cc729795fbcb045c938030f4c7a3ea6ed96226cab8b175fa8cb12710a74e738` |
| `terpd-6.2.0-dev-linux-amd64.tar.gz` | `3ec11bc7ec2886c4631f9573e790ada32e813f1d82017360255576614146f0eb` |
| `terpd-6.2.0-dev-linux-arm64.tar.gz` | `7fdfc0468387ac557f8acdd6d7388dcb76c1c6671b637f104056995e1862ba63` |

GNU BuildID (amd64): `68ff7ccf400f0ff11f63880d9d7e3b8eb9e76a10`  
GNU BuildID (arm64): `2ba50839cd17229e435156ea8985af2b2ffafe91`

No darwin pin this cut (Cosmovisor linux only). Stale `*-darwin-arm64.tar.gz` leftovers must not be in `plan.info`.

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
