# Fresh-VM release verification

Standard bit-for-bit check for **every** `vX.Y.Z` tag. The same `guest.sh`
runs on independent guests: clone the tag into an empty `GOPATH` /
`GOMODCACHE`, fetch checksummed `ibc-hooks-v11`, **rebuild** the muslc builder
image and `libwasmvm_muslc.*.a` from zk-wasmvm source, rebuild terpd images
with Docker Buildx `--no-cache`, compare to
`https://s3.terp.network/releases/terp-core/<tag>/sha256sum.txt`.

`WASMVM_MUSLC_FETCH=1` links the published muslc `.a` instead of rebuilding Rust
(faster, weaker).

Two Linux guests (Firecracker KVM + Wasmer-side Linux) matching S3 **and
each other** is the high-certainty path. Version extras stay in
[`releases/`](./releases/). Do not put guest/backend logic in
`recurate_upgrade_binaries.sh`.

## Guests

| `GUEST` / `GUESTS` | How | linux muslc | darwin/arm64 |
|--------------------|-----|-------------|--------------|
| `firecracker` | `FIRECRACKER_SSH=user@microvm` | yes (Docker in the VM) | no |
| `wasmer` | `WASMER_SSH=user@linux` (preferred) or `wasmer run $WASMER_PACKAGE` | SSH: yes. WASIX package: only if it has Docker | no |
| `local` | throwaway dir on this host | if this host has Docker | Darwin arm64 host only |

Auto-select: both SSH vars set → `firecracker,wasmer`. Else whichever SSH is
set. Else `local`.

```bash
TAG=v6.2.0 ./scripts/release/fresh-vm/run.sh
GUESTS=firecracker,wasmer TAG=v6.2.0 ./scripts/release/fresh-vm/run.sh
FIRECRACKER_SSH=root@fc WASMER_SSH=root@wasmer-linux TAG=v6.2.0 ./scripts/release/fresh-vm/run.sh
GUEST=wasmer WASMER_SSH=root@box TAG=v6.1.0 PLATFORMS=linux/amd64,linux/arm64 ./scripts/release/fresh-vm/run.sh
# WASIX (no Docker unless the package provides it):
GUEST=wasmer WASMER_PACKAGE=your/pkg TAG=v6.2.0 ./scripts/release/fresh-vm/run.sh
```

Wasmer WASIX is not a Linux VM. Public packages such as `sharrattj/bash` cannot
run `docker buildx`. For linux ELFs, point `WASMER_SSH` at a fresh Linux
builder (Wasmer Edge VM, or any clean host) the same way as Firecracker.

After each guest, hashes land in `/tmp/terp-fresh-toolkit-<tag>/out/<guest>.sha256sum.txt`.
Two guests → those files must agree on every overlapping ELF.

`scripts/release/verify_fresh_vm.sh` is a wrapper around `run.sh`.

Operator-facing record: [Release verification](https://docs.terp.network/guides/validators/release-verification) in terp-docs.
