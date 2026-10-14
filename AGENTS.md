# terp-core agent notes

Follow [CONTRIBUTING.md](CONTRIBUTING.md).

## Changelog

When a pull request changes operator-visible behavior, add one
`changelog/unreleased/<PR-number>.md` after the draft PR exists. Categories
are `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, and `Security`.
Internal-only work uses `<!-- changelog: none -->` and a reason. Do not edit
`networks/upgrades/<plan>/RELEASE.md` in an ordinary PR.

Steps: `skills/changelog-fragment/SKILL.md`.

## Releasing our forks

Preparing a release does not publish it. Ask before `git tag`, `git push`,
S3 upload, or `cargo publish`.

Primary, in this order. Each step consumes the tag from the step above. A
local path override is not a release.

1. **zakura-common** (`permissionlessweb/common`). Pin the git rev CosmWasm
   will build. Today's pin is `5364d3d`. A crates.io publish of those crates
   is a separate Common release, not this chain cut.
2. **cosmwasm** (`permissionlessweb/cosmwasm`). The only wasm-library
   submodule is `crates/cosmwasm`, branch `release/v6.3.0-wasmer`.
   libwasmvm pins that commit with `git` / `rev`, not a path. Workspace
   version is `[workspace.package]` in `crates/cosmwasm/Cargo.toml`.
   Do not move the `4.0.0-zk` tag onto this line.
3. **wasmvm** is in-tree at `x/wasm/wasmvm` (source
   `permissionlessweb/wasmvm` tag `4.0.0-zk`). Cargo version is `libwasmvm`
   `4.0.0-zk`. Go import stays `wasmvm/v3` (`replace => ./x/wasm/wasmvm`).
   Host libs come from `terpnetwork/zk-*-builder:4.0.0-zk`, never CosmWasm
   `0103-*`. Publish muslc to `releases/zk-wasmvm/v4.0.0-zk/`. Do not push
   the builder images.
4. **wasmd** is in-tree at `x/wasm`
   (`github.com/terpnetwork/terp-core/v6/x/wasm`). It is not a submodule.
5. **terp-core**. The CosmWasm gitlink matches the libwasmvm `rev`.
   wasmvm and wasmd are not submodules. Tag `v6.3.0`, then
   build `v6.4.0` (`-tags v64`) and put its tarball sha256 into v6.3's
   `NextUpgradeInfo` before the v6.3 tag is the one operators run. Linux ELFs
   and Cosmovisor JSON go to `s3.terp.network`. Operator image is
   `registry.terp.network/terp-core:<tag>`. Notes:
   `networks/upgrades/v6.3/RELEASE.md` and `v6.4/RELEASE.md`.

Secondary. Tag these after the primary tags they compile against exist. They
do not block the Cosmovisor ELF.

- **terp-rs** (`permissionlessweb/terp-rs`) — SDK and light-client contracts.
- **cw-orchestrator** (`permissionlessweb/cw-orchestrator`) — deploy and test
  tooling.
- **abstract** (`permissionlessweb/abstract`) — DAO contracts.
- **headstash** — airdrop: `hard-nett/airdrop` and
  `permissionlessweb/cw-headstash`.

Mechanics: `/skills/release-libraries/SKILL.md`.

## act

`scripts/ci/act.sh` is the way to run a workflow locally. It picks
`linux/arm64` or `linux/amd64` from the machine and deletes act containers
when the process exits. groot2 is amd64. This Mac is arm64. Do not pin the
other architecture in `.actrc`.
