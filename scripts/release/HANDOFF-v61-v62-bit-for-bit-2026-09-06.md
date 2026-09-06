# Handoff — bit-for-bit recuration of v6.1 and v6.2 upgrade binaries

**Date:** 2026-09-06  
**Audience:** an objective teammate who did not cut these ELFs.  
**Goal:** From the git SHAs we communicate, rebuild `terpd` linux/amd64 and linux/arm64 and show the sha256 matches `networks/upgrades/{v6.1,v6.2}/ARTIFACT_LOCK`. That is how operators know the Cosmovisor binary is the source we named.

Do **not** upload S3, tag a GitHub release, or broadcast gov. Heights stay TBD.

---

## 1. What these two upgrades are

Two coordinated halts, two binaries, two Cosmovisor plan directories.

| Plan | Branch | Binary commit (ELF identity) | What the handler does |
|------|--------|------------------------------|------------------------|
| **v6.1** | `feat/6.1.0-dev` | `10ea0bcce26d4e55ad09ea8362b7c222ee7d8c1f` | Upgrade A: copy migratable IAVL → `b3-*`. HashMerchant consensus **2**, sudo cap **100663296**. CosmWasm halt/gas isolation (nil-Ok, wasm-only reply events, cache-oblivious `UsedInternally`). IBC stays SHA-256. |
| **v6.2** | `feat/6.2.0-dev` | `d3d3bcd1d73b4c81f0fae88b00f30eb61969b631` | Upgrade B: keepers stay `bank`/`staking`/`acc`; unmounted `b3-*` dest trees drop from CommitInfo. Same CosmWasm pins as v6.1. IBC stays SHA-256. |

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
| terp-core v6.1 ELF | `10ea0bc` | sound-hash + Docker identity |
| terp-core v6.2 ELF | `d3d3bcd` | merge of `feat/6.1.0-dev` into Upgrade B |
| zk-wasmd | `5567942a` | nil-Ok including migrate; wasm-only reply |
| cosmwasm (packages/vm) | `d742487ff` | `used_internally_is_cache_oblivious` |
| zk-wasmvm | `ff7adf3` | unchanged for this slice |

Confirm:

```sh
git ls-tree HEAD crates/zk-wasmd crates/zk-wasmvm crates/cosmwasm
```

Muslc is **not** in git. Host must have STWO archives:

`crates/zk-wasmvm/internal/api/libwasmvm_muslc.aarch64.a`  
`crates/zk-wasmvm/internal/api/libwasmvm_muslc.x86_64.a`

Each must `grep -a -F verify_stwo_host_proof`. Expected sha256 of those `.a` files (cut host):

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

v6.1 lock file is also on `feat/6.1.0-dev` at `f5558cc` (pack commit). ELF identity remains `10ea0bc`.

The script fails closed if HEAD ≠ `binary_commit`, if the tree is dirty, if muslc lacks `verify_stwo_host_proof`, or if rebuilt sha256 ≠ lock.

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

### v6.1 (`10ea0bc`)

| File | sha256 |
|------|--------|
| `terpd-linux-amd64` | `df3bfc065652740bd3eda65775045ddb2822ec51c2045a09e6a47c462f777e55` |
| `terpd-linux-arm64` | `7eb17be606d00bf4edaa60064802e53fe25bf8590c6edcbb46f3c43868b72d79` |
| `terpd-6.1.0-dev-linux-amd64.tar.gz` | `f30fa00ed7b4d6233313cf6009c5af1baad8107228ef6dfd6b3f2f99af172b16` |
| `terpd-6.1.0-dev-linux-arm64.tar.gz` | `c7c858afe5c7a73f90333e5092ad1d6c103bdbc79e4a7356c4ccb47a1dcf3f05` |

GNU BuildID (arm64): `d791f11eed6dc6bf5ffdbdf4fc7a3c21bbd1d0e2`  
GNU BuildID (amd64): `83cf51e63a1a14af73a1059f442c05e2d6c29555`

Image used for HashMerchant gas e2e (not the Cosmovisor tarball):  
`registry.terp.network/terp-core:v6.1.0-dev-10ea0bc`  
`sha256:74976ff775151967464ae4a75e60918cd4dd10d515e92ecf68dbe108ca634a4a`

### v6.2 (`d3d3bcd`)

| File | sha256 |
|------|--------|
| `terpd-linux-amd64` | `0b67c5efc16a68ba39fff4270b03af8366289660481d65c28b07d39154183570` |
| `terpd-linux-arm64` | `6b7f54349b651f5ab8c7fd19d2f7beb03fd33aad918499bd3463ce957b32e2bd` |
| `terpd-6.2.0-dev-linux-amd64.tar.gz` | `71dda7c4424362fb6b34d21a4078ee774a14d4b6aa17e9c64d30cedff4fba19f` |
| `terpd-6.2.0-dev-linux-arm64.tar.gz` | `11e32ab051eea559299f85832816cbb28d3f0278039be42d0005abc2f14808f4` |

GNU BuildID (arm64): `6cdeba3eb2f174e34d38b9ff6b842629efb852f7`  
GNU BuildID (amd64): `b7ecf50b6272a1e6d655ac53c695f4693f2713f1`

No darwin pin on v6.2 this cut (stale leftover tarball was not rebuilt).

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
4. `file build/terpd-linux-*` is statically linked; `grep -a verify_stwo_host_proof` hits.
5. You can explain, from `git show $COMMIT` + `go.mod` replaces + muslc sha256, why the ELF hash is that hash.

If hashes diverge: first check muslc sha256, Go image digest (`golang:1.26.5-alpine@sha256:0178a641fbb4858c5f1b48e34bdaabe0350a330a1b1149aabd498d0699ff5fb2`), dirty tree, and that you did not recurate a pack-only commit.

---

## 8. QMD

| Field | Value |
|-------|--------|
| **Title** | v6.1 + v6.2 bit-for-bit Cosmovisor recuration |
| **lex** | `binary_commit ARTIFACT_LOCK recurate WASMVM_SOURCE=local verify_stwo_host_proof` |
| **vec** | How do we prove the upgrade ELF is the git tree we published? |
| **Anti-claim** | Matching a Docker tag is not ELF recuration; S3 URLs are not checksums until objects exist |
