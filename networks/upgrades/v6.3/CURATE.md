# Curate v6.3.0 / v6.4.0 — bit-for-bit ELFs

Do **not** upload S3, retag, or broadcast until asked. Heights stay TBD.

This is the hasher two-step that v6.1/v6.2 did **not** compile (no in-git IAVL
replace). Cosmovisor plan names: **`v6.3`** then **`v6.4`**. Not `v7`.

## 1. Pins that must be on the tags

| Input | Tip / version |
|-------|----------------|
| CosmWasm | `4.0.0-zk` `09e3ba815` (`crates/cosmwasm`) |
| libwasmvm | `4.0.0-zk` `de95b3f` (`crates/zk-wasmvm`) |
| zakura-halo2-proofs | `5364d3d` |
| Go import | **`github.com/CosmWasm/wasmvm/v3`** (path unchanged) |
| IAVL / store | `go.mod` replace `./crates/cosmos/iavl` and `./crates/cosmos/store-v2` |

Confirm:

```sh
git -C crates/cosmwasm rev-parse HEAD    # 09e3ba815
git -C crates/zk-wasmvm rev-parse HEAD   # de95b3f
grep -n 'iavl =>\|store/v2 =>\|wasmvm/v3 =>' go.mod
./scripts/release/curate_v63.sh
```

Build libwasmvm with **our** images (`terpnetwork/zk-*-builder:4.0.0-zk`),
published as `ghcr.io/terpnetwork/zk-*-builder:4.0.0-zk`. Never
`docker pull cosmwasm/libwasmvm-builder:0103-*` (rustc 1.86, no Path A).
Canonical: [`crates/zk-wasmvm/docs/BUILDERS.md`](../../../crates/zk-wasmvm/docs/BUILDERS.md).

```sh
(cd crates/zk-wasmvm/builders && make docker-images-4.0.0-zk)
make wasmvm-release-build   # muslc .a AND glibc .so AND dylib, then verify
make wasmvm-verify
```

`make docker-images` in the wasmvm builders dir **refuses** 0103. Linux `go
test` links the glibc `.so`, not muslc. Recutting only alpine is the
mixed-generation trip (`store_param` undefined). Host Darwin dylib is **not**
the Cosmovisor ELF. Operators get **linux muslc**
`libwasmvm_muslc.{aarch64,x86_64}.a` from `releases/zk-wasmvm/v4.0.0-zk/`.
Do **not** reuse v6.1 muslc sha256 (`0687e591…` / `4f4880e1…`) — those are
`93d4bce`.

Path A STWO host must still reject dummy DSTW (`grep -a -F 'stwo: Dummy DSTW rejected'`).

## 2. Two ELFs

| Plan | Tag | Build | Handler |
|------|-----|-------|---------|
| `v6.3` | `v6.3.0` | default tags | dest `b3-*` Added, KV copy, arm `v6.4` at +2 |
| `v6.4` | `v6.4.0` | `-tags v64` | keepers on dest, live SHA-256 names Deleted |

`terpd version` must print `6.3.0` / `6.4.0`, not a `-dev` describe string.
Both tags may sit on the **same source SHA**. Stamp `VERSION` from the tag
(`VERSION=6.4.0`), not `git describe`. v6.4 linux ELF is
`BUILD_TAGS=muslc v64` (Dockerfile ARG, `build-reproducible`).
Pack files (`ARTIFACT_LOCK`, proposals) may live on `release/v6.3.0` /
`release/v6.4.0` **without moving the ELF tag**.

## 3. Preflight (already the TSH gate)

```sh
go test ./app/upgrades/v6_3/ ./app/iavlhash ./app/wasmlc
go test -tags v64 ./app/upgrades/v6_4/
make tsh-upgrade          # morocco-1 pack + in-place-testnet dual-halt
```

Green means: dest bank BLAKE3, `ibc` SHA-256, `cw_template` survives, 08-wasm LC
accepts dest-bank membership. That is **not** bit-for-bit linux identity.

## 4. Recurate linux (when asked)

```sh
# rebuild muslc from crates/zk-wasmvm 4.0.0-zk, then:
TAG=v6.3.0 PLATFORMS=linux/amd64,linux/arm64 ./scripts/release/fresh-vm/run.sh
TAG=v6.4.0 BUILD_TAGS=v64 PLATFORMS=linux/amd64,linux/arm64 ./scripts/release/fresh-vm/run.sh
PLAN=v6.3 make recurate-upgrade-binaries
PLAN=v6.4 make recurate-upgrade-binaries
make verify-upgrade-pack PLAN=v6.3
make verify-upgrade-pack PLAN=v6.4
```

Fresh-VM extras: `scripts/release/fresh-vm/releases/v6.3.0.sh` and `v6.4.0.sh`.
`fresh_vm_verify` must fail if `go.mod` lacks the two hasher replaces.

Fill `ARTIFACT_LOCK` from the guest sha256. Do not copy v6.1 lock rows.

## 5. Pack contents (after lock exists)

Per plan dir `networks/upgrades/v6.3/` and `v6.4/`:

- `ARTIFACT_LOCK` — ELF sha256, `binary_commit`, wasmvm muslc sha256
- `binaries.json` / `cosmovisor.json` — same URLs and checksums
- `draft_proposal.json` — plan name `v6.3` only on the gov tx
- `SOURCE_DEPS.txt` — CosmWasm / wasmvm / zakura / iavl SHAs
- `guide.md` — operators pre-place **both** bins

`make verify-upgrade-pack` must show binaries.json == cosmovisor.json == lock.
`published: false` until linux tarballs are on S3; then `CHECK_S3=1`.

## 6. Locked non-goals

- Do not retag `v6.1.0` / `v6.2.0`.
- Do not `StoreUpgrades.Renamed` dest onto `bank`.
- Do not flip IAVL `DefaultOptions` to BLAKE3.
- Do not name the second Cosmovisor dir `v7` on this cut (handler is `v6.4`).
- Do not treat RecvPacket of hybrid `ibc` as the BLAKE3 proof.
- Do not invent S3 checksums. Fill lock rows from guest sha256 only.
- Do not `docker pull cosmwasm/libwasmvm-builder:0103-*` for this cut.
