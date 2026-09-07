# scripts/ci

Prebuilt-commit E2E. Design: [docs/workflows/prebuilt-e2e.md](../../docs/workflows/prebuilt-e2e.md).

| Script | Role |
|--------|------|
| `resolve-prebuilt.sh` | Print MinIO URLs for `PREBUILT_COMMIT` (else `GITHUB_SHA` / HEAD). |
| `fetch-prebuilt.sh` | Download terpd + image tar; check sha256. No compile. |
| `publish-prebuilt-commit.sh` | `mc cp` to `usb2/releases/terp-core/commits/<sha>/`. |
| `assert-identical.sh` | sha256 of two terpd files. |
| `terp-prebuilt.env` | Pin for terp-core MinIO folder (`PREBUILT_COMMIT`). |
| `pin-latest-prebuilts.sh` | Rewrite both pin files from newest MinIO `commits/<sha>/`. |
| `list-ict-ci-suites.sh` | JSON array from pinned `ict-ci list` (GHA matrix). |
| `fetch-ict-rs-bins.sh` | Download pin in `ict-rs-bins.env`. Works without `crates/ict-rs`. |
| `stage-zk-for-docker.sh` | Stage muslc + forks for `WASMVM_SOURCE=local`. Origin wasmvm must have `CircuitKeyLen`. `ibc-hooks-v11` from `HOOKS_SRC` or sha256-pinned `IBC_HOOKS_URL` (default object still under `v6.0.0-dev/` until relocated). |

Do not publish an arm64 ELF as `terpd-linux-amd64`.
