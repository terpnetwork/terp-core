# Related dependency releases (4.0.0-zk)

Craft these **before** tagging terp-core `v6.3.0` / `v6.4.0`. Do not retag
`v6.1.0` / `v6.2.0`. Do not S3-upload from this file.

Go import path for the VM stays **`github.com/CosmWasm/wasmvm/v3`**. Cargo /
libwasmvm version is **4.0.0-zk**.

| Repo | Tag | Tip on this tree | What to ship |
|------|-----|------------------|--------------|
| permissionlessweb/cosmwasm | `4.0.0-zk` | `09e3ba815` | std/vm, Path A fail-closed, poseidon377, in-tree bn254 |
| permissionlessweb/wasmvm | `4.0.0-zk` | `de95b3f` | libwasmvm + **new** muslc `.a` (not v3.0.7-zk); glibc `.so` from our debian-nightly |
| permissionlessweb/wasmd | tag when ready | `d08c754a` (`crates/zk-wasmd`) | consensus 4→5 migration |
| zakura-common | pin in SOURCE_DEPS | `a64b90a` (contains `5364d3d`) | Halo2 IPA CS/VK/PK codec, no dummy SNARKs |

## wasmvm host libs (bit-for-bit)

Dynamic libraries **must** be built with our Libwasm builder images, never
CosmWasm’s `libwasmvm-builder:0103-*`. See
[`crates/zk-wasmvm/docs/BUILDERS.md`](../../../crates/zk-wasmvm/docs/BUILDERS.md).

```sh
# OUR builders only — never cosmwasm/libwasmvm-builder:0103-*.
(cd crates/zk-wasmvm/builders && make docker-images-4.0.0-zk)
make wasmvm-release-build
make wasmvm-verify
# optional: push images
(cd crates/zk-wasmvm/builders && make docker-publish-4.0.0-zk)
# muslc (+ .so) to the releases bucket
./scripts/release/publish_zk_wasmvm.sh
```

Put muslc sha256 into `scripts/release/fetch_zk_muslc.sh` and
`scripts/release/fresh-vm/releases/v6.3.0.sh` **before** guest recurate.
Do not reuse `0687e591…` / `4f4880e1…`. S3 tree:
`releases/zk-wasmvm/v4.0.0-zk/`.

## terp-core linux ELFs

```sh
./scripts/release/curate_v63.sh
TAG=v6.3.0 PLATFORMS=linux/amd64,linux/arm64 ./scripts/release/fresh-vm/run.sh
TAG=v6.4.0 BUILD_TAGS=v64 PLATFORMS=linux/amd64,linux/arm64 ./scripts/release/fresh-vm/run.sh
# dual guest if FIRECRACKER_SSH and WASMER_SSH are set
```

Fill `ARTIFACT_LOCK` from guest sha256. `published: false` until linux
tarballs are uploaded. Then `PLAN=v6.3 make recurate-upgrade-binaries` and
the same for v6.4. `CHECK_S3=1` only after `published: true`.

## Commit order (suggested)

1. CosmWasm `4.0.0-zk` tag on `09e3ba815` (permissionlessweb/cosmwasm). Do
   **not** commit local `path = "../../../zakura-common"` dirty; the tag is
   the git rev `5364d3d`.
2. wasmvm `4.0.0-zk` (`de95b3f`) on permissionlessweb/wasmvm **after** host
   libs recut on our builders (glibc `.so` + dylib committed; muslc `.a` is
   gitignored and lives on S3).
3. wasmd tag if that repo is released independently (`d08c754a` is the pin).
4. terp-core: submodule gitlinks + hasher + upgrade docs, push
   `feat/6.3.0-dev`, then annotated tags `v6.3.0` and `v6.4.0` (same source
   SHA; v6.4 ELF is `-tags v64` + `VERSION=6.4.0` ldflags).

Heights stay TBD. Do not retag `v6.1.0` / `v6.2.0`. Do not invent checksums.
