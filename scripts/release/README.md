# Release & distribution scripts

Deterministic tooling to **label**, **build**, **checksum**, and **publish** Terp-Core
artifacts so operators (and oline) can pin **mainnet** vs **testnet/ZK** lineages
without drift.

## Lineages (do not mix)

| Lineage | Branch / tag | Docker (default) | S3 tree |
|---------|----------------|------------------|---------|
| **Mainnet** (stock CosmWasm wasmvm) | release tags e.g. `v5.2.0` | `ghcr.io/terpnetwork/terp-core:v5.2.0` | `snapshots/mainnet/morocco-1/` |
| **Testnet ZK** (monorepo + local zk-wasmvm) | `v5.3.0-dev` (and later `v5.3.0`) | `ghcr.io/terpnetwork/terp-core:v5.3.0-dev` | `releases/v5.3.0-dev/` + `snapshots/testnet/120u-1/` |

Build ZK images with `WASMVM_SOURCE=local` from this monorepo (`crates/zk-wasmvm`).

## Quick start — `v5.3.0-dev`

```bash
# 1) Branch
git checkout v5.3.0-dev   # or: git checkout -b v5.3.0-dev

# 2) Build ZK alpine image + tag as v5.3.0-dev (local + ghcr names)
make docker-publish-dev RELEASE_TAG=v5.3.0-dev
# Retag only (reuse existing :local-zk without rebuild):
# make docker-publish-dev RELEASE_TAG=v5.3.0-dev SKIP_BUILD=1

# 3) Push image (needs docker login to ghcr.io)
make docker-push-dev RELEASE_TAG=v5.3.0-dev

# 4) Bundle source + manifest (local build/release/<tag>/)
make release-bundle RELEASE_TAG=v5.3.0-dev

# 5) Publish bundle + optional network assets to MinIO/S3
#    MINIO_ALIAS defaults to usb2 (host MinIO); override as needed
make release-s3 RELEASE_TAG=v5.3.0-dev NETWORK=testnet CHAIN_ID=120u-1
# dry-run:
make release-s3 RELEASE_TAG=v5.3.0-dev NETWORK=testnet CHAIN_ID=120u-1 DRY_RUN=1
```

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
make docker-publish-dev RELEASE_TAG=v5.3.0-dev
make docker-push-dev RELEASE_TAG=v5.3.0-dev
```

## Scripts

| Script | Purpose |
|--------|---------|
| [`publish_docker_dev.sh`](./publish_docker_dev.sh) | ZK docker build + multi-tag (`local-zk`, `v5.3.0-dev`, ghcr) |
| [`make_release_bundle.sh`](./make_release_bundle.sh) | Deterministic `source.tar.gz`, git metadata, image digests, `manifest.json` |
| [`publish_s3_release.sh`](./publish_s3_release.sh) | `mc cp` bundle → `releases/<tag>/` + optional `snapshots/<network>/<chain>/` |
| [`prep.sh`](./prep.sh) | Goreleaser-era binary tarballs (mainnet-style) |

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

```
releases/<tag>/
  manifest.json
  SOURCE_COMMIT
  source.tar.gz
  source.tar.gz.sha256
  docker-images.txt
  sha256sum.txt                 # if binary artifacts present

snapshots/<network>/<chain_id>/
  releases/<tag> -> copied manifest pointer files (optional)
  scripts/oline-entrypoint.sh   # if SYNC_ENTRYPOINT=1 and file provided
  scripts/config-node-endpoints.sh
```

Public base: `https://s3.terp.network/` (via host MinIO + Cloudflare).

## Environment

| Variable | Default | Meaning |
|----------|---------|---------|
| `RELEASE_TAG` | `v5.3.0-dev` | Version label |
| `IMAGE_REPO` | `ghcr.io/terpnetwork/terp-core` | Registry repository |
| `WASMVM_SOURCE` | `local` for dev-zk builds | `local` = monorepo zk-wasmvm |
| `MINIO_ALIAS` | `usb2` | `mc` alias for host MinIO |
| `S3_BUCKET` | `snapshots` | Bucket name |
| `NETWORK` | `testnet` | `mainnet` \| `testnet` |
| `CHAIN_ID` | `120u-1` | e.g. `morocco-1` / `120u-1` |
| `DRY_RUN` | `0` | Print `mc` actions only |
| `SYNC_ENTRYPOINT` | `0` | Also push oline entrypoint scripts |
| `ENTRYPOINT_SRC` | path to `oline-entrypoint.sh` | Optional |

## oline pin (testnet)

After push:

```toml
# ~/.oline/config.toml
[testnet]
sentry_image = "ghcr.io/terpnetwork/terp-core:v5.3.0-dev"

[testnet.images]
node = "ghcr.io/terpnetwork/terp-core:v5.3.0-dev"
```
