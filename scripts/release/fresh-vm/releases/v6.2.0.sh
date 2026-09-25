# Historical extras for tag v6.2.0. Sourced by fresh-vm run.sh / guest.sh.
# ibc-hooks-v11 is gitignored — guest fetches the public tarball (checksummed).
# Same hasher situation as v6.1.0 (HASHER.md).

export IBC_HOOKS_URL="${IBC_HOOKS_URL:-https://minio.terp.network/releases/terp-core/v6.0.0-dev/ibc-hooks-v11.tar.gz}"
export IBC_HOOKS_SHA256="${IBC_HOOKS_SHA256:-1b31faa98bedb7e388eef97ed031143a851b0d8a799b52d7b1b3ab78c898a312}"
export WASMVM_MUSLC_BASE="${WASMVM_MUSLC_BASE:-https://minio.terp.network/releases/zk-wasmvm/v3.0.7-zk}"
export WASMVM_MUSLC_AARCH64_SHA="${WASMVM_MUSLC_AARCH64_SHA:-0687e59140c967a752b0b0ede98e71a3c859fb4f6b94fc26883792d381eb4716}"
export WASMVM_MUSLC_X86_SHA="${WASMVM_MUSLC_X86_SHA:-4f4880e1655d34c098729df52db22c9253bec87d2b3185669ff015a340b76d49}"
export FRESH_VM_BUILDER_FROM="${FRESH_VM_BUILDER_FROM:-rust:1.88.0-alpine}"

fresh_vm_host_stage() {
  local extras="$1"
  local lock="${HOST_ROOT:-}/networks/upgrades/v6.2/ARTIFACT_LOCK"
  if [ -f "$lock" ]; then
    cp -f "$lock" "$extras/ARTIFACT_LOCK"
  fi
}

fresh_vm_verify() {
  if [ -d crates/cosmos/iavl ] || [ -d crates/cosmos/store-v2 ]; then
    echo "ERROR: hasher vendor present on fresh v6.2.0 clone (must not ship in the tag)" >&2
    fail=1
  fi
  if grep -q 'replace github.com/cosmos/cosmos-sdk/store/v2 => ./crates/cosmos/store-v2' go.mod; then
    echo "NOTE: tag replaces store/v2 — hasher patch is in this ELF lineage"
  else
    echo "NOTE: v6.2.0 does not replace store/v2; live CMS hasher is stock SHA-256"
  fi
  local lock="$EXTRAS/ARTIFACT_LOCK"
  [ -f "$lock" ] || return 0
  local name want got
  for name in terpd-linux-amd64 terpd-linux-arm64; do
    want="$(awk -v n="$name" '$2==n {print $1; exit}' "$lock")"
    [ -n "$want" ] || continue
    [ -f "build/$name" ] || continue
    got="$(sha256_file "build/$name")"
    if [ "$got" != "$want" ]; then
      echo "ERROR: $name rebuilt $got != ARTIFACT_LOCK $want" >&2
      fail=1
    else
      echo "OK $name matches ARTIFACT_LOCK"
    fi
  done
}
