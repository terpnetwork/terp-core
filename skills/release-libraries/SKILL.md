---
name: release-libraries
description: >-
  Prepare a coordinated release of our maintained forks: zakura-common,
  cosmwasm, wasmvm, wasmd, then terp-core, and after that terp-rs,
  cw-orchestrator, abstract, and headstash. Use when cutting those tags,
  publishing muslc or Cosmovisor artifacts, or asking what has to ship first.
---

# Release our forks

This is not the Zakura Common crates.io skill. That one publishes 17
`zakura-*` crates bottom-up. Do not run it from terp-core, and do not edit
Zakura's release skill.

The order and the current pins are in `AGENTS.md` and
`networks/upgrades/v6.3/DEPS-RELEASE.md`. If they disagree, the dependency
file is the pin list and `AGENTS.md` is the order.

## Safety

- Preparing or reviewing a release does not publish it. Ask immediately
  before a tag, a push, an S3 upload, or `cargo publish`.
- Do not retag `v6.1.0` or `v6.2.0`.
- Do not move `v6.3.0` or `v6.4.0` unless the user asks. Those tags are the
  published ELF identity. A new link flag or a new commit does not match the
  published sha256.
- A `path =` dependency is a working tree. The tagged commit must use a git
  rev or a released version.

## Primary

Ship in this order. Stop on the first red step.

1. **zakura-common** — `github.com/permissionlessweb/common`.
   Record the rev (`5364d3d` on the current cut). Do not publish those
   crates unless the user asked for a Common crates.io release.
2. **cosmwasm** — `github.com/permissionlessweb/cosmwasm`, checkout
   `crates/cosmwasm`. Version is `[workspace.package].version` (`4.0.0-zk`).
   Tag `4.0.0-zk` on the commit that pins the Common rev. Push the tag to
   the `fork` remote, not to upstream CosmWasm.
3. **wasmvm** — `github.com/permissionlessweb/wasmvm`, checkout
   `crates/zk-wasmvm`. `libwasmvm` version `4.0.0-zk`. Go module path stays
   `github.com/CosmWasm/wasmvm/v3`.
   - Builders: `terpnetwork/zk-*-builder:4.0.0-zk` only.
   - `make wasmvm-release-build` then `make wasmvm-verify`.
   - Muslc upload is `./scripts/release/publish_zk_wasmvm.sh` (write alias
     `usb2`). Builders stay on the build machine.
4. **wasmd** — `github.com/permissionlessweb/wasmd`, checkout
   `crates/zk-wasmd`. Tag the commit the chain replace will use. No tag
   until that commit is the one you mean.
5. **terp-core** — gitlinks for the three submodules match the tags above.
   - Build `v6.4.0` with `-tags v64` first. Stamp
     `app/upgrades/v6_3/constants.go` from
     `networks/upgrades/v6.4/cosmovisor.json`
     (`scripts/release/stamp_v63_next_info.sh`).
   - Then tag `v6.3.0` on the commit that contains those checksums.
   - Linux ELFs: `LINK_STATICALLY=true` (`ld.bfd`, `-static-pie`). Pack with
     `scripts/release/pack_cv_tarball.sh` so the archive member is `terpd`.
   - Publish tarballs and `cosmovisor.json`. `published: true` only after the
     public sha256 matches the lock.
   - Operator image: `registry.terp.network/terp-core:<tag>`.
   - Notes: `networks/upgrades/v6.3/RELEASE.md`, `v6.4/RELEASE.md`.

## Secondary

Only after the primary tag they compile against exists. None of these is the
Cosmovisor binary.

- **terp-rs** (`permissionlessweb/terp-rs`) — SDK and `cw-ics08-wasm-*`.
- **cw-orchestrator** (`permissionlessweb/cw-orchestrator`) — daemon and
  interchain test helpers.
- **abstract** (`permissionlessweb/abstract`) — DAO contracts, branch
  `v3.1.0-zk.0`.
- **headstash** — `hard-nett/airdrop` and `permissionlessweb/cw-headstash`.

Bump their CosmWasm or wasmvm dependency to the tag from the primary cut,
then tag that repo. Do not vendor those trees into terp-core to make the
release.

## Changelog

terp-core fragments: `changelog/unreleased/<PR-number>.md` (see
`changelog-fragment`). The assembled upgrade note is the plan `RELEASE.md`,
written when that release is cut, not on an ordinary PR.

The other forks keep their own changelog if they have one. Do not require
Zakura's `scripts/changelog.py` in wasmd, wasmvm, or cosmwasm.
