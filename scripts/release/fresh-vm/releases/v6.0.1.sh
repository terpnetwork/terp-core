# Historical extras for tag v6.0.1. Sourced by fresh-vm run.sh / guest.sh.
# ibc-hooks-v11 is gitignored — guest fetches the public tarball (checksummed).
# Muslc is rebuilt from zk-wasmvm source unless WASMVM_MUSLC_FETCH=1.

export IBC_HOOKS_URL="${IBC_HOOKS_URL:-https://minio.terp.network/releases/terp-core/v6.0.0-dev/ibc-hooks-v11.tar.gz}"
export IBC_HOOKS_SHA256="${IBC_HOOKS_SHA256:-1b31faa98bedb7e388eef97ed031143a851b0d8a799b52d7b1b3ab78c898a312}"
export WASMVM_MUSLC_BASE="${WASMVM_MUSLC_BASE:-https://minio.terp.network/releases/zk-wasmvm/v3.0.7-zk}"
export WASMVM_MUSLC_AARCH64_SHA="${WASMVM_MUSLC_AARCH64_SHA:-0687e59140c967a752b0b0ede98e71a3c859fb4f6b94fc26883792d381eb4716}"
export WASMVM_MUSLC_X86_SHA="${WASMVM_MUSLC_X86_SHA:-4f4880e1655d34c098729df52db22c9253bec87d2b3185669ff015a340b76d49}"
export FRESH_VM_BUILDER_FROM="${FRESH_VM_BUILDER_FROM:-rust:1.88.0-alpine}"
