# Historical extras for tag v6.3.0 (feat/6.3.0-dev). Hasher replaces must be on the tag.

export IBC_HOOKS_URL="${IBC_HOOKS_URL:-https://minio.terp.network/releases/terp-core/v6.0.0-dev/ibc-hooks-v11.tar.gz}"
export IBC_HOOKS_SHA256="${IBC_HOOKS_SHA256:-1b31faa98bedb7e388eef97ed031143a851b0d8a799b52d7b1b3ab78c898a312}"
# Muslc recut 2026-09-21 from wasmvm 4.0.0-zk caefa92 (Path A DSTW reject).
export WASMVM_MUSLC_BASE="${WASMVM_MUSLC_BASE:-https://minio.terp.network/releases/zk-wasmvm/v4.0.0-zk}"
export WASMVM_MUSLC_AARCH64_SHA="${WASMVM_MUSLC_AARCH64_SHA:-4adc7b3ca25340a18f38cf313d6cd6d9a8bac0e86cd31799534a04eec1c75ea2}"
export WASMVM_MUSLC_X86_SHA="${WASMVM_MUSLC_X86_SHA:-892b623f7a8df2caf40c038461f7a9f9545a381aef3de35c0e4a297f25c98bd7}"
export FRESH_VM_BUILDER_FROM="${FRESH_VM_BUILDER_FROM:-rust:1.88.0-alpine}"

fresh_vm_verify() {
  if ! grep -q 'github.com/cosmos/iavl => ./crates/cosmos/iavl' go.mod; then
    echo "ERROR: v6.3.0 tag missing iavl replace — hasher will not compile" >&2
    fail=1
  fi
  if ! grep -q 'github.com/cosmos/cosmos-sdk/store/v2 => ./crates/cosmos/store-v2' go.mod; then
    echo "ERROR: v6.3.0 tag missing store/v2 replace" >&2
    fail=1
  fi
}
