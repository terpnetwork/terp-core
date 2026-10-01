#!/usr/bin/env bash
# Fail-closed Cosmovisor pack: ARTIFACT_LOCK ↔ binaries.json ↔ cosmovisor.json
# ↔ (optional) live S3 sha256sum.txt. Does not upload.
#
#   PLAN=v6.3 ./scripts/release/verify_upgrade_pack.sh
#   PLAN=v6.3 CHECK_S3=1 ./scripts/release/verify_upgrade_pack.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=upgrade_pack_lib.sh
source "$ROOT/scripts/release/upgrade_pack_lib.sh"

PLAN="${PLAN:-}"
[ -n "$PLAN" ] || { echo "ERROR: set PLAN=v6.3 or PLAN=v6.4" >&2; exit 1; }
PACK="$(pack_dir)"
LOCK="$(lock_path)"
CHECK_S3="${CHECK_S3:-0}"
[ -f "$LOCK" ] || { echo "ERROR: missing $LOCK" >&2; exit 1; }

published="$(lock_field "$LOCK" published)"
tag="$(lock_field "$LOCK" binary_tag)"
s3_base="$(lock_field "$LOCK" s3_binaries_intended)"
s3_base="${s3_base%/}"

hex_from_lock() {
  awk -v n="$1" '$2 == n {print $1; exit}' "$LOCK"
}

json_sha() {
  local file="$1" plat="$2"
  python3 - "$file" "$plat" <<'PY'
import json, re, sys
p, plat = sys.argv[1], sys.argv[2]
data = json.load(open(p))
url = (data.get("binaries") or {}).get(plat, "")
m = re.search(r"checksum=sha256:([0-9a-f]{64})", url)
print(m.group(1) if m else "")
PY
}

# --- wasmvm host libs in the tree vs lock ---
API="$ROOT/crates/zk-wasmvm/internal/api"
bash "$ROOT/crates/zk-wasmvm/builders/host/verify_libwasmvm.sh"

want_x86="$(hex_from_lock libwasmvm_muslc.x86_64.a)"
want_arm="$(hex_from_lock libwasmvm_muslc.aarch64.a)"
if [ -n "$want_x86" ]; then
  got="$(sha256_file "$API/libwasmvm_muslc.x86_64.a")"
  [ "$got" = "$want_x86" ] || { echo "ERROR: muslc x86 $got != lock $want_x86" >&2; exit 1; }
fi
if [ -n "$want_arm" ]; then
  got="$(sha256_file "$API/libwasmvm_muslc.aarch64.a")"
  [ "$got" = "$want_arm" ] || { echo "ERROR: muslc arm $got != lock $want_arm" >&2; exit 1; }
fi
echo "OK $LOCK wasmvm muslc matches tree"

# --- binaries.json == cosmovisor.json ---
BJ="$PACK/binaries.json"
CJ="$PACK/cosmovisor.json"
if [ -f "$BJ" ] && [ -f "$CJ" ]; then
  for plat in linux/amd64 linux/arm64; do
    a="$(json_sha "$BJ" "$plat")"
    b="$(json_sha "$CJ" "$plat")"
    [ -n "$a" ] || { echo "ERROR: $BJ missing $plat checksum" >&2; exit 1; }
    [ "$a" = "$b" ] || { echo "ERROR: $plat binaries.json $a != cosmovisor.json $b" >&2; exit 1; }
    echo "OK $plat pack json $a"
  done
  # lock tarball rows (not raw ELF sha) vs Cosmovisor JSON
  ver="${tag#v}"
  for pair in "amd64 terpd-${ver}-linux-amd64.tar.gz" "arm64 terpd-${ver}-linux-arm64.tar.gz"; do
    set -- $pair
    locksha="$(hex_from_lock "$2")"
    [ -n "$locksha" ] || continue
    jsha="$(json_sha "$BJ" "linux/$1")"
    [ "$locksha" = "$jsha" ] || { echo "ERROR: lock $2 $locksha != json $jsha" >&2; exit 1; }
  done
  echo "OK binaries.json == cosmovisor.json"
else
  if [ "$published" = "true" ]; then
    echo "ERROR: published=true but missing $BJ or $CJ" >&2
    exit 1
  fi
  echo "OK pack json not written yet (published=$published)"
fi

# --- live S3 ---
if [ "$CHECK_S3" = "1" ] || [ "$published" = "true" ]; then
  [ -n "$s3_base" ] || { echo "ERROR: no s3_binaries_intended" >&2; exit 1; }
  sums="$(mktemp)"
  trap 'rm -f "$sums"' RETURN
  if ! curl -fsSL "$s3_base/sha256sum.txt" -o "$sums"; then
    echo "ERROR: cannot fetch $s3_base/sha256sum.txt (published=$published)" >&2
    exit 1
  fi
  echo "OK fetched $s3_base/sha256sum.txt"
  if [ -f "$BJ" ]; then
    for plat in linux/amd64 linux/arm64; do
      jsha="$(json_sha "$BJ" "$plat")"
      grep -q "$jsha" "$sums" || { echo "ERROR: S3 sha256sum.txt missing $plat $jsha" >&2; exit 1; }
    done
    echo "OK S3 sha256sum.txt contains pack checksums"
  fi
fi

echo "OK verify-upgrade-pack PLAN=$PLAN tag=${tag:-?} published=${published:-?}"
