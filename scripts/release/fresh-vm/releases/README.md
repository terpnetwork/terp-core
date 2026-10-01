# Per-tag verification extras

One file per published tag: `vX.Y.Z.sh`. Sourced by `run.sh` (host) and
`guest.sh` (clone). Leave this file alone once that tag is published; copy it
to the next tag and edit the copy.

Optional hooks:

| Hook | Where | Purpose |
|------|--------|---------|
| `fresh_vm_host_stage <extras-dir>` | host, before copy/SSH | Optional pack files (`ARTIFACT_LOCK`). Not source. |
| `fresh_vm_prepare` | guest, after clone | Override default: submodules, fetch ibc-hooks, rebuild muslc |
| `fresh_vm_verify` | guest, after S3 compare | Extra checks. Set `fail=1` to fail the run |

Guest default (permissionless): fetch checksummed `ibc-hooks-v11.tar.gz`, rebuild
the alpine muslc **builder image** and the `.a` from zk-wasmvm + cosmwasm source,
then `docker buildx --no-cache` terpd. `WASMVM_MUSLC_FETCH=1` skips the Rust
rebuild and links the published `.a` (weaker).

Exports: `IBC_HOOKS_URL`, `IBC_HOOKS_SHA256`, `WASMVM_MUSLC_*_SHA`,
`FRESH_VM_BUILDER_FROM`.
