# Historical extras for tag v6.4.0 (keepers on dest, -tags v64). Hasher replaces must be on the tag.

export IBC_HOOKS_URL="${IBC_HOOKS_URL:-https://minio.terp.network/releases/terp-core/v6.0.0-dev/ibc-hooks-v11.tar.gz}"
export IBC_HOOKS_SHA256="${IBC_HOOKS_SHA256:-1b31faa98bedb7e388eef97ed031143a851b0d8a799b52d7b1b3ab78c898a312}"
# Same 4.0.0-zk muslc as v6.3.0 (2026-09-29 recut, wasmvm e799f70).
export WASMVM_MUSLC_BASE="${WASMVM_MUSLC_BASE:-https://minio.terp.network/releases/zk-wasmvm/v4.0.0-zk}"
export WASMVM_MUSLC_AARCH64_SHA="${WASMVM_MUSLC_AARCH64_SHA:-ec9afa36668bcdccbfce99d7529a59556403f0456a5fe00b898a05c19dd7b06c}"
export WASMVM_MUSLC_X86_SHA="${WASMVM_MUSLC_X86_SHA:-927ce262d5e06735f77cd304e48e15c003c00ec93b57b5fbc277ad319010e771}"
export FRESH_VM_BUILDER_FROM="${FRESH_VM_BUILDER_FROM:-rust:1.88.0-alpine}"
# Keepers on dest. Docker linux ELF is muslc + v64 (build.mk prepends muslc).
export BUILD_TAGS="${BUILD_TAGS:-v64}"

fresh_vm_verify() {
  if ! grep -q 'github.com/cosmos/iavl => github.com/permissionlessweb/iavl' go.mod; then
    echo "ERROR: v6.4.0 tag missing external iavl replace — hasher will not compile" >&2
    fail=1
  fi
  if ! grep -q 'github.com/cosmos/cosmos-sdk/store/v2 => github.com/permissionlessweb/cosmos-sdk/store/v2' go.mod; then
    echo "ERROR: v6.4.0 tag missing external store/v2 replace" >&2
    fail=1
  fi
}
