# Cross Compilation Scripts

As this library is targeting go developers, we cannot assume a properly set up
rust environment on their system. Further, when importing this library, there is
no clean way to add a `libwasmvm.{so,dll,dylib}`. It needs to be committed with
the tagged (go) release in order to be easily usable.

The solution is to precompile the rust code into libraries for the major
platforms (Linux, Windows, macOS) and commit them to the repository at each
tagged release. This should be doable from one host machine, but is a bit
tricky. This folder contains build scripts and a Docker image to create all
dynamic libraries from one host. In general this is set up for a Linux host, but
any machine that can run Docker can do the cross-compilation.

## 4.0.0-zk: our images only

**Do not pull `cosmwasm/libwasmvm-builder:0103-*`.** Those are rustc 1.86 and
do not compile Path A. Dynamic libraries (glibc `.so`, Darwin dylib) and muslc
archives for this fork are built with:

| Image | Output |
|-------|--------|
| `terpnetwork/zk-alpine-builder:4.0.0-zk` | muslc `.a` |
| `terpnetwork/zk-debian-builder:4.0.0-zk` | glibc `.so` |
| `terpnetwork/zk-cross-builder:4.0.0-zk` | osxcross (optional) |

Local tags only (`terpnetwork/zk-*-builder:4.0.0-zk`). Do not push to GHCR
or `registry.terp.network`. Canonical write-up:
[`docs/BUILDERS.md`](../docs/BUILDERS.md).

```sh
make docker-images-4.0.0-zk
# make docker-images   # refuses 0103
```

## Historical CosmWasm Docker Hub images

Upstream CosmWasm (not this fork):

- From version 0100: https://hub.docker.com/r/cosmwasm/libwasmvm-builder/tags
- Before version 0100: https://hub.docker.com/r/cosmwasm/go-ext-builder/tags

## Changelog

**Unreleased**

**Version 0102:**

- Update Rust to 1.82.0.

**Version 0101:**

- Update Rust to 1.81.0.
- Update Dockerfile.cross from Debian Bullseye to Bookworm ([#533])
- Rename `.cargo/config` to `.cargo/config.toml` to silence warning

[#533]: https://github.com/CosmWasm/wasmvm/issues/533

**Version 0100:**

- Rename builder image from cosmwasm/go-ext-builder to
  cosmwasm/libwasmvm-builder
- Replace CentOS with Debian image for GNU linux builds
- Avoid using a target folder in the host system. Instead the folder /target in
  the guest is used. Due to this change we can now drop the argument
  `-u $(USER_ID):$(USER_GROUP)` when using builders. ([#437])
- Build all images with `--platform=linux/amd64` to avoid accidental ARM builds

[#437]: https://github.com/CosmWasm/wasmvm/issues/437

**Version 0019:**

- Bump `OSX_VERSION_MIN` to 10.15.
- Update Rust to 1.77.0.

**Version 0018:**

- Remove Go dev environment from `cosmwasm/go-ext-builder:XXXX-alpine`
- Write x86_64 muslc output in `libwasmvm_muslc.x86_64.a` instead of
  `libwasmvm_muslc.a`

**Version 0017:**

- Update Rust to 1.73.0.
- Update Go to 1.20.10 (for testing only).

**Version 0016:**

- Update Rust to 1.69.0.
- Let `build_muslc.sh` use `--example wasmvmstatic` instead of `--example muslc`

**Version 0015:**

- Update Rust to 1.68.2.
- Update Go (for testing only) to 1.19.7.
- Add `build_macos_static.sh` to cross builders for macOS build.

**Version 0014:**

- Update Rust to 1.65.0.
- Update Go (for testing only) to 1.18.8.

**Version 0013:**

- Update Rust to 1.63.0 in `Dockerfile.alpine` and `Dockerfile.cross`;
  `Dockerfile.centos7` was accidentally not updated and remained on 1.60.0
  ([#350]).
- Add Windows support to cosmwasm/go-ext-builder:0013-cross. This image builds
  for macOS and Windows now.

[#350]: https://github.com/CosmWasm/wasmvm/pull/350

**Version 0012:**

- Add cross-compilation setup to build `libwasmvm.x86_64.so` and
  `libwasmvm.aarch64.so` from the CentOS builder image.
- Update Rust to 1.60.0.

**Version 0011:**

- Update Rust to 1.59.0.

**Version 0010:**

- Add cross-compilation setup to build `libwasmvm_muslc.a` and
  `libwasmvm_muslc.aarch64.a` from the alpine builder image.

**Version 0009:**

- Let macOS build dylib files with both aarch64 and x86_64 code.
- Update Go (for testing only) to 1.17.7.

**Version 0008:**

- Update Rust to 1.55.0 and Go (for testing only) to 1.17.5.

**Version 0007:**

- Do not copy output from the target folder to final destination. The caller
  should do that.
- Update Rust to 1.53.0.

**Version 0006:**

- Update Rust to 1.51.0.

**Version 0005:**

- Update Rust to 1.50.0.

**Version 0004:**

- Update Rust to 1.49.0.
- Alpine: Update Go to 1.15

**Version 0003:**

- Avoid pre-fetching of dependencies to decouple builders from source code.
- Bump `OSX_VERSION_MIN` to 10.10.
- Use `rust:1.47.0-buster` as base image for cross compilation to macOS

**Version 0002:**

- Update hardcoded library name from `libgo_cosmwasm` to `libwasmvm`.

**Version 0001:**

- First release of builders that is versioned separately of CosmWasm.
- Update Rust to nightly-2020-10-24.

## Usage

**4.0.0-zk: use our images only.** Do not `docker pull cosmwasm/libwasmvm-builder:0103-*`.
Those are rustc 1.86 and do not compile Path A. Build ours once:

```sh
(cd builders && make docker-images-4.0.0-zk)
# terpnetwork/zk-alpine-builder:4.0.0-zk   muslc .a
# terpnetwork/zk-debian-builder:4.0.0-zk   glibc .so
# terpnetwork/zk-cross-builder:4.0.0-zk    osxcross (optional; Darwin native is supported)
```

Upstream `make docker-images` (0103) is CosmWasm’s line, not this fork.

Then in the **wasmvm repo root** (`crates/zk-wasmvm`):

```sh
(cd builders && make docker-images-4.0.0-zk)   # once: nightly alpine+debian+cross
make release-build                             # muslc .a AND glibc .so AND dylib
make verify-libwasmvm                          # fail if .so/.a are mixed generations
```

From **terp-core**:

```sh
make wasmvm-release-build    # same, via crates/zk-wasmvm
make wasmvm-verify
```

Linux `go test` links `internal/api/libwasmvm.$(arch).so`, **not** the muslc `.a`.
Recutting only alpine is how 4.0.0-zk Go bindings (`store_param`) failed to link
against a leftover 3.0.7-zk `.so`. `verify-libwasmvm` exists so that cannot
happen again.

**macOS dylib:** on Darwin, `make build-libwasmvm` (native) is the supported recut.
`make release-build-macos` uses osxcross and currently fails Path A on
`x86_64-apple-darwin` (`__rust_probestack`). Do not replace a good native
`libwasmvm.dylib` with a failed lipo. Native static: `make release-build-macos-static-arm64`.

4.0.0-zk Path A needs rustc nightly. Upstream `0103-*` images are 1.86. Use
`docker-images-4.0.0-zk` (alpine-nightly / debian-nightly / cross-nightly).

## Future Work

- Add support for cross-compiling to Windows as well.
- Publish docker images when they are stable
