# Historical extras for tag v6.3.0 (feat/6.3.0-dev). Hasher replaces must be on the tag.

export IBC_HOOKS_URL="${IBC_HOOKS_URL:-https://minio.terp.network/releases/terp-core/v6.0.0-dev/ibc-hooks-v11.tar.gz}"
export IBC_HOOKS_SHA256="${IBC_HOOKS_SHA256:-1b31faa98bedb7e388eef97ed031143a851b0d8a799b52d7b1b3ab78c898a312}"
# Muslc recut 2026-09-29 from wasmvm e799f70 and CosmWasm 5f141e70.
export WASMVM_MUSLC_BASE="${WASMVM_MUSLC_BASE:-https://minio.terp.network/releases/zk-wasmvm/v4.0.0-zk}"
export WASMVM_MUSLC_AARCH64_SHA="${WASMVM_MUSLC_AARCH64_SHA:-3cb0e887c678eb934bec05800ffdfeb017bb57f931bd40c17f7ff9fe0c96ca34}"
export WASMVM_MUSLC_X86_SHA="${WASMVM_MUSLC_X86_SHA:-c5d5dec1410d537b75358747caf29316d862d785b24a54a2b9c24d94e9364621}"
export FRESH_VM_BUILDER_FROM="${FRESH_VM_BUILDER_FROM:-rust:1.88.0-alpine}"

fresh_vm_verify() {
  if ! grep -q 'github.com/cosmos/iavl => github.com/permissionlessweb/iavl' go.mod; then
    echo "ERROR: v6.3.0 tag missing external iavl replace — hasher will not compile" >&2
    fail=1
  fi
  if ! grep -q 'github.com/cosmos/cosmos-sdk/store/v2 => github.com/permissionlessweb/cosmos-sdk/store/v2' go.mod; then
    echo "ERROR: v6.3.0 tag missing external store/v2 replace" >&2
    fail=1
  fi
}
