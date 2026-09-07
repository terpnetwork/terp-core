# Release & distribution scripts

Deterministic tooling to **label**, **build**, **checksum**, and **publish** Terp-Core
artifacts so operators (and oline) can pin **mainnet** vs **testnet/ZK** lineages
without drift.

## Lineages (do not mix)

| Lineage | Branch / tag | Docker (default) | S3 tree |
|---------|----------------|------------------|---------|
| **Mainnet** (stock CosmWasm wasmvm) | release tags e.g. `v5.2.0` | `containers.terp.network/terp-core:v5.2.0` | `snapshots/mainnet/morocco-1/` |
| **Testnet ZK** (monorepo + local zk-wasmvm) | `v5.3.0-dev` (and later `v5.3.0`) | `containers.terp.network/terp-core:v5.3.0-dev` | `releases/terp-core/v5.3.0-dev/` + `snapshots/testnet/120u-1/` |

Build ZK images with `WASMVM_SOURCE=local` from this monorepo (`crates/zk-wasmvm`).

## Quick start — `v6.0.0-dev`

```bash
# 1) Branch
git checkout v6.0.0-dev

# 2) Build ZK alpine image + tag as v5.3.0-dev (local + ghcr names)
make docker-publish-dev RELEASE_TAG=v6.0.0-dev
# Retag only (reuse existing :local-zk without rebuild):
# make docker-publish-dev RELEASE_TAG=v6.0.0-dev SKIP_BUILD=1

# 3) Push image (needs docker login to containers.terp.network)
make docker-push-dev RELEASE_TAG=v6.0.0-dev

# 4) Bundle source + manifest (local build/release/<tag>/)
make release-bundle RELEASE_TAG=v6.0.0-dev

# 5) Publish bundle to releases/<project>/<tag>/ on MinIO/S3
#    PROJECT defaults to terp-core (repo name). MINIO_ALIAS defaults to usb2.
make release-s3 RELEASE_TAG=v6.0.0-dev PROJECT=terp-core NETWORK=testnet CHAIN_ID=120u-1
# dry-run:
make release-s3 RELEASE_TAG=v6.0.0-dev DRY_RUN=1
```

**S3 layout (all projects):** see [`S3-LAYOUT.md`](./S3-LAYOUT.md) — bucket `releases` → `<project>/<tag>/`.

### Rebuild notes (ZK static link)

**Always keep** the monorepo replaces in `go.mod` on this branch:

```go
github.com/CosmWasm/wasmd => ./crates/zk-wasmd
github.com/CosmWasm/wasmvm/v3 => ./crates/zk-wasmvm
```

`make docker-publish-dev` runs `build-zk-local` with `WASMVM_SOURCE=local`, which:

1. Stages `crates/zk-*` → `build/zk-deps/zk-*` (because `.dockerignore` excludes `crates/`)
2. Stages muslc `.a` → `build/wasmvm/`
3. Dockerfile rewrites those replaces to `/code/build/zk-deps/...` and links the ZK `.a`

That way Go uses the ZK CGO API (pin/pin_circuit, **not** stock `sync_pinned_codes`) and the
static library matches. **Do not** drop the replaces and only swap the `.a` — that mixes
stock CosmWasm Go (needs `sync_pinned_codes`) with a ZK muslc archive and fails link.

Stock mainnet images: `WASMVM_SOURCE=github` strips the two replaces and downloads the
official CosmWasm muslc release.

```bash
make docker-publish-dev RELEASE_TAG=v6.0.0-dev
make docker-push-dev RELEASE_TAG=v6.0.0-dev
```

## Scripts

After publishing a tag pack: `make verify-artifacts RELEASE_TAG=v6.0.0` (S3 checksums, muslc, docker image == ELF, ict-rs).

Before a Cosmovisor upgrade (local artifacts, no S3): `WRITE=1 PLAN=v6.1 make preflight-upgrade RELEASE_TAG=v6.1.0`. `RELEASE_TAG` must be **vX.Y.Z** (the git tag). That rejects `file://` plans, requires tarball member `terpd`, and records per-arch libwasmvm checksums.

### Release control (same as v6.0.0)

ELF identity is an **annotated git tag** `vX.Y.Z` on the frozen source commit. Cosmovisor checksums, `ARTIFACT_LOCK`, and proposal JSON live on branch **`release/vX.Y.Z`**, which may be ahead of the tag. Never retag. Never stamp `vX.Y.Z-dev`, `rc`, or git-describe into `terpd`.

```bash
# freeze source, then:
RELEASE_TAG=v6.1.0 BINARY_COMMIT=<sha> make release-control
git checkout v6.1.0
RELEASE_TAG=v6.1.0 WASMVM_SOURCE=local make create-binaries
git checkout release/v6.1.0
WRITE=1 PLAN=v6.1 RELEASE_TAG=v6.1.0 make release-prep
# commit lock/proposal on release/v6.1.0 only — do not move tag v6.1.0
```

Cosmovisor `tar.gz` files are packed by `pack_cv_tarball.py` (Python stdlib, not `tar -czf`): USTAR, `mtime=$SOURCE_DATE_EPOCH` (tag commit `%ct`), uid/gid 0, gzip `-9` with `mtime=0`. Same ELF → same tarball hash on macOS and Linux. Recurate runs this packer from the **pack branch**, not the tagged worktree.

`crates/ibc-hooks-v11` is gitignored. Recurate copies `HOOKS_SRC` (default that path) or fetches a **sha256-pinned** tarball (`IBC_HOOKS_SHA256`). Submodule pin is the follow-up so a bare clone does not need MinIO.


| Script | Purpose |
|--------|---------|
| [`publish_docker_dev.sh`](./publish_docker_dev.sh) | ZK docker build + multi-tag (`local-zk`, `v5.3.0-dev`, ghcr) |
| [`make_release_bundle.sh`](./make_release_bundle.sh) | Deterministic `source.tar.gz`, git metadata, image digests, `manifest.json` |
| [`publish_s3_release.sh`](./publish_s3_release.sh) | `mc cp` bundle → `releases/<project>/<tag>/` + snapshot pointer |
| [`S3-LAYOUT.md`](./S3-LAYOUT.md) | Canonical multi-project MinIO layout |
| [`prep.sh`](./prep.sh) | Versioned Cosmovisor tarballs via `pack_cv_tarball.py` |
| [`pack_cv_tarball.py`](./pack_cv_tarball.py) | Reproducible `terpd` member tarball (SOURCE_DATE_EPOCH) |
| [`recurate_upgrade_binaries.sh`](./recurate_upgrade_binaries.sh) | Rebuild tagged ELF + compare `ARTIFACT_LOCK` |
| [`ensure_release_control.sh`](./ensure_release_control.sh) | Create/verify tag `vX.Y.Z` + branch `release/vX.Y.Z` |

## Manifest (verifiability)

Each release writes `build/release/<tag>/manifest.json` with:

- `git_commit`, `git_tree`, `dirty` (working tree dirty flag)
- `source.tar.gz` + `sha256`
- Docker image refs + **RepoDigests** when available
- `source_date_epoch` for reproducible archives
- `network` / `chain_id` / `lineage` (`mainnet-stock` \| `testnet-zk`)

Anyone can re-run `make_release_bundle.sh` on the same commit and compare checksums
(modulo `dirty=true` if local edits remain).

## S3 layout

Full spec: [`S3-LAYOUT.md`](./S3-LAYOUT.md).

```
# Bucket: releases  (source + binaries for every project)
releases/<project>/<tag>/
  manifest.json
  SOURCE_COMMIT
  source.tar.gz
  source.tar.gz.sha256
  docker-images.txt
  sha256sum.txt                 # if binary artifacts present

# Bucket: snapshots  (network ops only)
snapshots/<network>/<chain_id>/
  genesis.json, chain.json, scripts/
  releases/<project>/<tag>/     # lightweight pointer to software release
```

Public base: `https://s3.terp.network/` (via host MinIO + Cloudflare).

Examples:

- `https://s3.terp.network/releases/terp-core/v5.3.0-dev/manifest.json`
- `https://s3.terp.network/releases/terp-core/latest/manifest.json`

## Environment

| Variable | Default | Meaning |
|----------|---------|---------|
| `RELEASE_TAG` | `v5.3.0-dev` | Version label |
| `PROJECT` / `RELEASE_PROJECT` | `terp-core` | Folder under releases bucket (repo name) |
| `IMAGE_REPO` | `containers.terp.network/terp-core` | Registry repository |
| `WASMVM_SOURCE` | `local` for dev-zk builds | `local` = monorepo zk-wasmvm |
| `MINIO_ALIAS` | `usb2` | `mc` alias for host MinIO |
| `S3_BUCKET` | `releases` | Target bucket for source bundles |
| `NETWORK` | `testnet` | `mainnet` \| `testnet` |
| `CHAIN_ID` | `120u-1` | e.g. `morocco-1` / `120u-1` |
| `DRY_RUN` | `0` | Print `mc` actions only |
| `PUBLISH_LATEST` | `0` | Also write `releases/<project>/latest/` |
| `SYNC_ENTRYPOINT` | `0` | Also push oline entrypoint scripts |
| `ENTRYPOINT_SRC` | path to `oline-entrypoint.sh` | Optional |

## oline pin (testnet)

After push:

```toml
# ~/.oline/config.toml
[testnet]
sentry_image = "containers.terp.network/terp-core:v5.3.0-dev"

[testnet.images]
node = "containers.terp.network/terp-core:v5.3.0-dev"
```


## ZK libwasmvm artifacts

Run make target wasmvm-curate. It copies every libwasmvm* from crates/zk-wasmvm
into build/wasmvm-release/ plus SHA256SUMS and VERSIONS.txt.

wasmd CheckLibwasmVersion requires the rust CARGO_PKG_VERSION (3.0.7-zk) to be
a substring of the Go wasmvm module version. A path replace to ./crates/zk-wasmvm
reports (devel) and the check is a no-op. Tag ZK releases so go.mod require is
v3.0.7-zk (or set rust version to 3.0.7 to match v3.0.7).

Goreleaser linux hooks copy build/wasmvm-release muslc archives when present
so published linux binaries link the curated ZK muslc instead of the official
CosmWasm GitHub asset.


## Expedited v6 upgrade pack

Plan name on-chain is **`v6`**. Cosmovisor directory: `cosmovisor/upgrades/v6/bin/terpd`.

```bash
make create-binaries
make release-prep RELEASE_TAG=v6.0.0
make create-binaries-json RELEASE_TAG=v6.0.0
make create-upgrade-guide-v6 PROPOSAL_ID=<id> UPGRADE_BLOCK=<height>
./scripts/release/create_proposal/submit_proposal.sh --height <H> --tag v6.0.0 --name v6
make tsh-upgrade-cv   # Cosmovisor auto-swap rehearsal
```
