# Terp-Core monorepo and git submodules

This repository is a **Go monorepo** for the Terp Network chain (`terpd`, `x/*`, protos, Docker, tests) that also vendors a large set of **Rust / CosmWasm / IBC related repositories** under `crates/` as **git submodules**.

The submodule list is defined only in [`.gitmodules`](.gitmodules). This guide is derived from that file (61 modules at time of writing). If the list drifts, trust `.gitmodules` and refresh this document.

Related reading:

- [README.md](README.md) - chain build, tests, Docker, protobuf
- [SECURITY.md](SECURITY.md) - issues and disclosure
- [docker/README.md](docker/README.md) - local chain and faucet

---

## 1. Clone with submodules

Preferred (one step):

```sh
git clone --recursive https://github.com/terpnetwork/terp-core.git
cd terp-core
```

If you already cloned without submodules:

```sh
git clone https://github.com/terpnetwork/terp-core.git
cd terp-core
git submodule update --init --recursive
```

Notes:

- `--recursive` also initializes nested submodules inside submodule repos when those repos declare their own.
- A full recursive checkout is **large** (many remote forks under `crates/`). For chain-only Go work you may skip submodules, but any workflow that builds or path-depends on `crates/*` needs them initialized.
- Default remote for this tree is typically `origin` -> `terpnetwork/terp-core`. Forks and additional remotes are fine; submodule URLs still come from `.gitmodules` unless you override them locally.

Shallow clone (faster, less history) still needs submodule init:

```sh
git clone --depth 1 --recursive https://github.com/terpnetwork/terp-core.git
```

Some submodule remotes may reject very shallow nested clones; if init fails, retry without `--depth` for the parent or for the failing submodule.

---

## 2. Initialize and update submodules

### First-time init (after a plain clone)

```sh
git submodule update --init --recursive
```

Equivalent older form:

```sh
git submodule init
git submodule update --recursive
```

### Refresh to the commits recorded by the parent repo

After `git pull` (or checkout of another branch) on **terp-core**:

```sh
git pull
git submodule update --init --recursive
```

This checks out **exactly the gitlink commits** stored in the parent tree. It does **not** automatically move submodules to the tip of their remote branches.

### Pull latest from each submodule's tracked branch (advanced)

Only do this when you intentionally want to advance submodule pointers:

```sh
# Update every submodule to the remote tip of the branch named in .gitmodules
git submodule update --init --remote --recursive
```

Then you must **commit the new gitlink SHAs in the parent** (see section 3). Leaving dirty gitlinks uncommitted is a common source of "works on my machine" drift.

### Status and diagnostics

```sh
git submodule status
git submodule summary
# From parent: show gitlinks and dirty flags
git status
```

Status prefixes:

- leading space: checked out at the recorded commit
- `+`: submodule commit differs from what the parent records (local advance or detached mismatch)
- `-`: not initialized
- `U`: merge conflicts in the gitlink

---

## 3. Working with submodule changes

Submodules are **separate repositories** pinned by a **gitlink** (mode `160000`) in the parent. Correct flow is always: commit inside the submodule first, push that repo, then record the new SHA in the parent.

### Edit and commit inside a submodule

```sh
cd crates/example-crate   # replace with a real path from the inventory below
git status
git checkout -b my-fix   # or the branch from .gitmodules
# ... edit ...
git add -A
git commit -m "Describe the change"
git push origin HEAD
```

If the submodule is in detached HEAD (normal after `submodule update`), create or checkout a branch before committing:

```sh
git switch -c my-fix
# or: git switch mvp   # when .gitmodules names branch = mvp
```

### Record the new pointer in terp-core

```sh
cd /path/to/terp-core
git status
# should show modified crates/example-crate (new commits)
git add crates/example-crate
git commit -m "chore(submodules): bump example-crate"
git push
```

Reviewers should see a one-line path change with old/new SHAs, not a full file diff inside the submodule.

### Bump one submodule to a known commit or branch tip

```sh
cd crates/example-crate
git fetch origin
git checkout <commit-or-branch>
cd ../..
git add crates/example-crate
git commit -m "chore(submodules): pin example-crate to <short-sha>"
```

### Bump using `.gitmodules` branch tracking

```sh
git submodule update --remote crates/example-crate
git add crates/example-crate
git commit -m "chore(submodules): track remote branch for example-crate"
```

### Do not

- Commit Go/Rust build artifacts from a submodule into the parent by accident (`git add crates/foo` when you meant files in the parent).
- Rewrite submodule history that others already pinned without coordinating.
- Assume `git pull` in the parent updates submodule working trees (it does not; run `git submodule update`).

---

## 4. Directory structure overview

High-level layout of the **parent** repository (not every path is a submodule):

| Path | Role |
|------|------|
| `cmd/` | Go entrypoints (for example `terpd`) |
| `x/` | Cosmos SDK modules for Terp |
| `proto/` | Protobuf definitions |
| `app/`, `server/`, `api/` | Application wiring and APIs |
| `docker/` | Localnet, faucet, images |
| `scripts/`, `tests/`, `tools/` | Tooling and test harnesses |
| `docs/` | Project docs (audits, plans, research notes) |
| `networks/` | Network metadata helpers |
| `Makefile`, `go.mod` | Primary Go build surface (`make install`) |
| `crates/` | Git submodules + additional local crates/workspaces |
| `.gitmodules` | Canonical submodule inventory |

### What lives under `crates/`

Two different things share the `crates/` directory name:

1. **Git submodules** listed in `.gitmodules` (table below). These are independent remotes pinned by SHA.
2. **Non-submodule trees** that may exist locally (extra experiments, vendored trees, or workspaces). Those are ordinary directories or nested git checkouts **not** declared in `.gitmodules`. Do not treat every `crates/*` folder as a submodule.

The crate path `crates/monorepo` (when present) is a **crate/workspace name**, not this guide. This document is `MONOREPO.md` at the repository root.

### Functional groups among submodules (informal)

These groupings are for orientation only; remotes and branches remain authoritative in `.gitmodules`.

- **CosmWasm core and WASM VM**: `cosmwasm`, `zk-wasmvm`, `zk-wasmd`, `zk-wasmd.bak`, `cw-storage-plus`, `cw-multi-test`, `cw-multi-test-fork`, `clone-cw-multi-test`, `core-cosmwasm`
- **CW contract ecosystems**: `cw-plus`, `cw-plus-plus`, `cw-packages`, `cw-nfts`, `cw-asset`, `cw-minus`, `cw-orchestrator`, `cw-ica-controller`, `cw-ibc-demo`, `cw-infuser`, `cw-headstash`, `dao-contracts`, `polytone`, `polytone-evm`, `proxy-accounts`, `token-bindings`, `xion-account`, `abstract`, `abstract-account`, `abstract-cw-plus`, `wynddex`, `wynd-lsd`, `headstash`, `shitstrap`, `terp-account-billboards`, `terp-rs`
- **IBC / Tendermint / chains tooling**: `ibc-rs`, `ibc-proto-rs`, `ibc-types`, `ibc-middleware`, `ics23`, `tendermint-rs`, `hermes`, `interchaintest`, `ict-rs`, `basecoin-rs`, `commonware-abci`, `tower-abci`
- **ZK / crypto / ledger-adjacent**: `halo2-axiom`, `blst`, `jmt`, `sparse-merkle-tree`, `cnidarium`, `namada`, `penumbra`, `pbjson`, `smart-account-auth`
- **Neutron / Osmosis test helpers**: `neutron-std`, `neutron-test-tube`, `osmosis-rust`, `osmosis-test-tube`, `cosmos-rust`

---

## 5. Submodule inventory (from `.gitmodules`)

Authoritative source: [`.gitmodules`](.gitmodules). **61** entries:

| Path | Branch (tracking) | URL |
|------|-------------------|-----|
| `crates/abstract` | `mvp` | https://github.com/permissionlessweb/abstract |
| `crates/abstract-account` | `main` | https://github.com/burnt-labs/abstract-account/ |
| `crates/abstract-cw-plus` | `cw3` | https://github.com/permissionlessweb/abstract-cw-plus |
| `crates/basecoin-rs` | `main` | https://github.com/permissionlessweb/basecoin-rs |
| `crates/blst` | `master` | https://github.com/permissionlessweb/blst |
| `crates/clone-cw-multi-test` | `cw3/adapt_for_local_execution` | https://github.com/permissionlessweb/cw-multi-test-fork |
| `crates/cnidarium` | `main` | https://github.com/permissionlessweb/cnidarium |
| `crates/commonware-abci` | `main` | https://github.com/permissionlessweb/commonware-abci |
| `crates/core-cosmwasm` | `main` | https://github.com/permissionlessweb/core-cosmwasm |
| `crates/cosmos-rust` | `main` | https://github.com/permissionlessweb/cosmos-rust |
| `crates/cosmwasm` | `mvp-fix` | https://github.com/permissionlessweb/cosmwasm.git |
| `crates/cw-asset` | `zk-mvp` | https://github.com/permissionlessweb/cw-asset |
| `crates/cw-headstash` | `feat/halo2` | https://github.com/permissionlessweb/cw-headstash |
| `crates/cw-ibc-demo` | `cosmwasm3` | https://github.com/permissionlessweb/cw-ibc-demo |
| `crates/cw-ica-controller` | `zk-mvp` | https://github.com/permissionlessweb/cw-ica-controller |
| `crates/cw-infuser` | `cw-svg` | https://github.com/permissionlessweb/cw-infuser |
| `crates/cw-minus` | `main` | https://github.com/permissionlessweb/cw-minus |
| `crates/cw-multi-test` | `zk-mvp` | https://github.com/permissionlessweb/cw-multi-test.git |
| `crates/cw-multi-test-fork` | `zk-mvp` | https://github.com/permissionlessweb/cw-multi-test-fork |
| `crates/cw-nfts` | `cw3` | https://github.com/permissionlessweb/cw-nfts |
| `crates/cw-orchestrator` | `cw3` | https://github.com/permissionlessweb/cw-orchestrator |
| `crates/cw-packages` | `feat/cw3` | https://github.com/permissionlessweb/cw-packages |
| `crates/cw-plus` | `main` | https://github.com/permissionlessweb/cw-plus |
| `crates/cw-plus-plus` | `feat/mvp` | https://github.com/permissionlessweb/cw-plus-plus.git |
| `crates/cw-storage-plus` | `main` | https://github.com/permissionlessweb/cw-storage-plus/ |
| `crates/dao-contracts` | `feat/calander` | https://github.com/permissionlessweb/dao-contracts |
| `crates/halo2-axiom` | `mvp` | https://github.com/permissionlessweb/halo2-axiom |
| `crates/headstash` | `zk-mvp` | https://github.com/hard-nett/airdrop/ |
| `crates/hermes` | `master` | https://github.com/permissionlessweb/hermes |
| `crates/ibc-middleware` | `main` | https://github.com/permissionlessweb/ibc-middleware |
| `crates/ibc-proto-rs` | `main` | https://github.com/permissionlessweb/ibc-proto-rs |
| `crates/ibc-rs` | `main` | https://github.com/permissionlessweb/ibc-rs |
| `crates/ibc-types` | `main` | https://github.com/permissionlessweb/ibc-types |
| `crates/ics23` | `stable` | https://github.com/permissionlessweb/ics23 |
| `crates/ict-rs` | `main` | https://github.com/permissionlessweb/ict-rs |
| `crates/interchaintest` | `luca/fix-deps` | https://github.com/noble-assets/interchaintest |
| `crates/jmt` | `main` | https://github.com/permissionlessweb/jmt |
| `crates/namada` | `main` | https://github.com/permissionlessweb/namada |
| `crates/neutron-std` | `zk-mvp` | https://github.com/permissionlessweb/neutron-std |
| `crates/neutron-test-tube` | `dev` | https://github.com/permissionlessweb/neutron-test-tube |
| `crates/osmosis-rust` | `cw3` | https://github.com/permissionlessweb/osmosis-rust |
| `crates/osmosis-test-tube` | `cw3` | https://github.com/permissionlessweb/osmosis-test-tube |
| `crates/pbjson` | `main` | https://github.com/permissionlessweb/pbjson |
| `crates/penumbra` | `main` | https://github.com/permissionlessweb/penumbra/ |
| `crates/polytone` | `bump/cw3` | https://github.com/permissionlessweb/polytone |
| `crates/polytone-evm` | `evm/zk-mvp` | https://github.com/permissionlessweb/polytone |
| `crates/proxy-accounts` | `zk-mvp` | https://github.com/MegaRockLabs/proxy-accounts |
| `crates/shitstrap` | `main` | https://github.com/hard-nett/shitstrap |
| `crates/smart-account-auth` | `main` | https://github.com/permissionlessweb/smart-account-auth |
| `crates/sparse-merkle-tree` | `main` | https://github.com/permissionlessweb/sparse-merkle-tree |
| `crates/tendermint-rs` | `main` | https://github.com/permissionlessweb/tendermint-rs |
| `crates/terp-account-billboards` | `main` | https://github.com/permissionlessweb/terp-account-billboards |
| `crates/terp-rs` | `feat/zk-wasmvm` | https://github.com/permissionlessweb/terp-rs.git |
| `crates/token-bindings` | `mvp` | https://github.com/permissionlessweb/token-bindings |
| `crates/tower-abci` | `main` | https://github.com/permissionlessweb/tower-abci |
| `crates/wynd-lsd` | `cw3` | https://github.com/abstractsdk/wynd-lsd |
| `crates/wynddex` | `mvp` | https://github.com/permissionlessweb/wynddex |
| `crates/xion-account` | `cw3` | https://github.com/permissionlessweb/contracts |
| `crates/zk-wasmd` | `mvp` | https://github.com/permissionlessweb/wasmd |
| `crates/zk-wasmd.bak` | `mvp` | https://github.com/permissionlessweb/wasmd |
| `crates/zk-wasmvm` | `mvp` | https://github.com/permissionlessweb/wasmvm |

Most remotes are under `permissionlessweb` forks; a few come from `burnt-labs`, `hard-nett`, `noble-assets`, `MegaRockLabs`, and `abstractsdk`. Branch names often track experimental lines (`mvp`, `zk-mvp`, `cw3`, feature branches) rather than upstream `main`.

---

## 6. Common pitfalls and troubleshooting

### Empty `crates/*` directories after clone

**Symptom:** paths exist but have no files; builds cannot find crates.

**Fix:**

```sh
git submodule update --init --recursive
```

### `git pull` left submodules on old commits

**Symptom:** parent branch moved; your submodule working trees still match yesterday.

**Fix:**

```sh
git submodule update --init --recursive
```

### Detached HEAD when committing in a submodule

**Symptom:** `git commit` warns about detached HEAD; push is awkward.

**Fix:** create or switch to a branch (preferably the branch named in `.gitmodules`), commit, push, then bump the parent gitlink.

### Dirty `+` in `git submodule status`

**Symptom:** local submodule SHA does not match parent gitlink.

**Decide:** either commit the new gitlink in the parent, or reset the submodule:

```sh
git submodule update --checkout crates/example-crate
```

### Auth failures / private forks

**Symptom:** `Permission denied` or 404 on submodule fetch.

**Fix:** ensure SSH or HTTPS credentials can read each URL in `.gitmodules`. For forks you do not need, you can leave them uninitialized if your task does not touch them (partial checkout), knowing that recursive builds may fail.

### Nested submodule failures

**Symptom:** outer submodule checks out, but nested ones fail.

**Fix:**

```sh
git submodule update --init --recursive
# or enter the submodule and init there
cd crates/example-crate && git submodule update --init --recursive
```

### Accidental full history in PRs

**Symptom:** PR shows thousands of files under `crates/foo`.

**Cause:** submodule was not registered correctly (ordinary files committed instead of a gitlink), or someone extracted a submodule into the parent tree.

**Fix:** restore the path as a proper submodule entry and gitlink; do not vendor the full history into terp-core without an explicit decision.

### `zk-wasmd` and `zk-wasmd.bak`

Both point at `permissionlessweb/wasmd` on branch `mvp`. Treat them as **two pins** (possibly different SHAs) for experimental/backup layouts. Confirm which path your scripts and Cargo patches reference before bumping either.

### Branch name typos in tracking branches

Some tracking branch names are historical (for example `feat/calander`). `git submodule update --remote` follows whatever string is in `.gitmodules`, not a "corrected" spelling on the remote. If the remote renamed the branch, update `.gitmodules` and the submodule pin in a deliberate commit.

### Disk space and CI time

Full recursive checkout of all 61 modules is heavy. CI and local scripts often init only the subsets they need. Prefer explicit paths:

```sh
git submodule update --init crates/cosmwasm crates/zk-wasmvm
```

### Syncing this document

When adding or removing a submodule:

1. Update `.gitmodules` and the gitlink via normal git submodule commands.
2. Recount modules and refresh the inventory table in this file.
3. Mention the change in the parent commit message.

---

## 7. Quick reference

```sh
# Clone
git clone --recursive https://github.com/terpnetwork/terp-core.git

# After plain clone or branch switch
git submodule update --init --recursive

# See drift
git submodule status

# Work in one module
cd crates/terp-rs
git switch feat/zk-wasmvm   # branch from .gitmodules
# commit + push inside submodule
cd ../..
git add crates/terp-rs && git commit -m "chore(submodules): bump terp-rs"

# Chain-only build (Go), after clone
make install
```

For day-to-day chain development, start with [README.md](README.md) Quick Start. Use this file whenever you clone, pin, or bump anything under `crates/` that is listed in `.gitmodules`.
