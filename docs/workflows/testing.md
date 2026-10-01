# Testing Workflow

E2E (IBC + polytone) uses commit-keyed prebuilts. 

# Prebuilt-commit E2E

CI does not compile `terpd` or `ict-ci` on the test job. Tests run immediately
against bits already stored on our object store. A rebuild (when enabled) runs
in parallel and only asserts identity.

## Object store

Host: `https://minio.terp.network` (path-style). Alias for publish: `usb2`.

```
releases/terp-core/commits/<full-sha>/
  terpd-linux-amd64
  terpd-linux-amd64.sha256
  terp-core-local-linux-amd64.tar   # docker save of terpnetwork/terp-core:local
  manifest.json
  SOURCE_COMMIT

releases/ict-rs/commits/<full-sha>/
  ict-ci-linux-x86_64.tar.gz
  ict-ci-linux-x86_64.tar.gz.sha256
  manifest.json
  SOURCE_COMMIT
```

Identity is the sha256 of the **binary** (`terpd` or unpacked `ict-ci`), not the
image/tarball timestamps.

The name `*-linux-amd64` / `linux-x86_64` is a contract: `file(1)` / ELF
`e_machine` must be x86-64. Do not publish an arm64 binary under that name.

## Job graph

`interchaintest-E2E.yml` is called by `ci-dev.yml` and `ci-release.yml` after
`heavy-ci-gate`. It does not compile ict-rs.

| Job | What it does |
|-----|--------------|
| `discover-suites` | `fetch-ict-rs-bins.sh` for `ICT_RS_COMMIT`, then `ict-ci list`. |
| `e2e-tests` | Fetch pinned terp-core image. `docker load`. `ict-ci run <suite>`. |

ELF identity on `release/**` is `ci-release.yml` (`recurate` amd64 vs `ARTIFACT_LOCK`), not this workflow.

`act` / GitHub: `if: ${{ !env.ACT }}` skips `upload-artifact` (act has no token).

## Pins (so a CI-script commit does not 404)

- Terp image: `scripts/ci/terp-prebuilt.env` → `PREBUILT_COMMIT`.
  `resolve-prebuilt.sh` uses that pin, then `GITHUB_SHA` / HEAD.
- ict-rs bins: `scripts/ci/ict-rs-bins.env` → `ICT_RS_COMMIT`.
  `fetch-ict-rs-bins.sh` does not use `GITHUB_SHA`.
- Refresh both from MinIO: `scripts/ci/pin-latest-prebuilts.sh`.
  The E2E matrix is `ict-ci list` of that ict-rs pin, not a hardcoded suite list.

To test a **new** commit: recure linux/amd64, `publish-prebuilt-commit.sh`, then
move the pin to that SHA. Do not flip the pin to `${{ github.sha }}` until that
folder exists on MinIO.

## Recure + publish (linux/amd64)

Host Docker can be arm64. Cross-build:

```sh
# stage local zk forks (origin/v3.0.7-zk lacks CircuitKeyLen) + muslc x86_64 from MinIO
# then:
docker buildx build --builder terpbuilder --platform linux/amd64 \
  --target runtime --build-arg WASMVM_SOURCE=local \
  --build-arg RUNNER_IMAGE=alpine:3.17 \
  -t terpnetwork/terp-core:local-linux-amd64 --load -f Dockerfile .

docker create --platform linux/amd64 terpnetwork/terp-core:local-linux-amd64
# docker cp …/terpd  →  TERPD=
docker tag terpnetwork/terp-core:local-linux-amd64 terpnetwork/terp-core:local
docker save terpnetwork/terp-core:local -o IMAGE_TAR=
# restore host :local if you overwrote an arm64 tag

file "$TERPD"   # must say x86-64
TERPD=… IMAGE_TAR=… PREBUILT_COMMIT=$(git rev-parse HEAD) \
  scripts/ci/publish-prebuilt-commit.sh
```

ict-rs linux bins: `just ci-build-docker` then
`TARBALL=dist/ict-ci-linux-x86_64.tar.gz just ci-publish-prebuilt`.
Publish under the SHA that **produced** the bits.

## Local proof (`act`)

Do not compile in the test job.

```sh
act workflow_dispatch -j e2e-tests \
  -W .github/workflows/interchaintest-E2E.yml \
  --container-architecture linux/amd64 \
  -P ubuntu-latest=catthehacker/ubuntu:act-latest \
  --bind
```

`-j e2e-tests` leaves `rebuild` off. Suites must print PASSED.

## Why rebuild is off

`permissionlessweb/wasmvm` branch `v3.0.7-zk` is behind local
`crates/zk-wasmvm` (`CircuitKeyLen` + store-ID lock). Staging from origin and
compiling wasmd @ `merge/upstream-wasmd-v0.70` fails with
`undefined: wasmvm.CircuitKeyLen`. Enable `rebuild` only after that tag contains
the same `lib.go` the prebuilt used.

Wasmvm muslc for the image comes from
`https://minio.terp.network/releases/zk-wasmvm/<ver>/`, not CosmWasm GitHub.

## ict-rs mirror

Same layout and graph live under `crates/ict-rs/scripts/ci/` and
`crates/ict-rs/.github/workflows/e2e-prebuilt.yml` (`workflow_dispatch` only).
`Dockerfile.ci` is the linux/amd64 rebuild path (context = parent `crates/`).

