#!/usr/bin/env bash
# Local upgrade-pack gate. Complements verify_artifacts.sh (published S3).
# Does not upload, tag, or broadcast.
#
#   PLAN=v6.1 TAG=v6.1.0-dev ./scripts/release/preflight_upgrade.sh
#   WRITE=1  ...   rewrite networks/upgrades/$PLAN/cosmovisor.json from local tarballs
#
# Cosmovisor auto-download needs compact plan.info:
#   {"binaries":{"linux/amd64":"https://…/terpd-…-linux-amd64.tar.gz?checksum=sha256:<hex>"}}
# The tarball member must be `terpd` (DAEMON_NAME). file:// and raw ELF paths are not valid.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

PLAN="${PLAN:-v6.1}"
TAG="${TAG:-${RELEASE_TAG:-v6.1.0-dev}}"
VER="${TAG#v}"
PACK="${PACK:-$ROOT/networks/upgrades/${PLAN}}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
ZK="${ZK_WASMVM_DIR:-$ROOT/crates/zk-wasmvm}"
WASMVM_OUT="${WASMVM_ARTIFACT_DIR:-$ROOT/build/wasmvm-release}"
WRITE="${WRITE:-0}"
ALLOW_PARTIAL="${ALLOW_PARTIAL:-1}"
SKIP_WASMVM_CURATE="${SKIP_WASMVM_CURATE:-0}"
S3_BASE="${S3_BASE:-https://s3.terp.network/releases/terp-core/${TAG}}"
fail=0
warn=0

sha256_file() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

note() { echo "preflight: $*"; }
err()  { echo "ERROR: $*" >&2; fail=1; }
wrn()  { echo "WARN: $*" >&2; warn=$((warn + 1)); }

echo "=== preflight upgrade pack ==="
echo "  PLAN=$PLAN  TAG=$TAG  PACK=$PACK  WRITE=$WRITE"

# ------------------------------------------------------------------
# Plan directory + gov name
# ------------------------------------------------------------------
if [ ! -d "$PACK" ]; then
  err "missing $PACK"
elif [ -f "$PACK/draft_proposal.json" ]; then
  if command -v jq >/dev/null; then
    name="$(jq -r '.messages[0].plan.name // empty' "$PACK/draft_proposal.json")"
    if [ "$name" != "$PLAN" ]; then
      err "draft_proposal plan.name='$name' != PLAN='$PLAN'"
    else
      note "OK draft_proposal plan.name=$PLAN"
    fi
  else
    wrn "jq missing; skipped draft_proposal name check"
  fi
else
  wrn "no $PACK/draft_proposal.json"
fi

# ------------------------------------------------------------------
# ZK go.mod replaces
# ------------------------------------------------------------------
for pair in \
  "github.com/CosmWasm/wasmd => ./crates/zk-wasmd" \
  "github.com/CosmWasm/wasmvm/v3 => ./crates/zk-wasmvm"
do
  if ! grep -F "$pair" go.mod >/dev/null; then
    err "missing go.mod replace: $pair"
  fi
done
if grep -q 'github.com/CosmWasm/wasmvm/v3 => github.com/CosmWasm/wasmvm' go.mod; then
  err "stock wasmvm replace — ZK lineage required"
fi
[ "$fail" -eq 0 ] && note "OK go.mod ZK replaces"

# ------------------------------------------------------------------
# libwasmvm per-arch artifacts
# ------------------------------------------------------------------
if [ "$SKIP_WASMVM_CURATE" = "1" ]; then
  wrn "SKIP_WASMVM_CURATE=1"
elif [ -f "$ROOT/scripts/release/curate_wasmvm_artifacts.sh" ]; then
  if ! bash "$ROOT/scripts/release/curate_wasmvm_artifacts.sh"; then
    err "wasmvm-curate failed"
  fi
fi

has_sym() {
  local f="$1" s="$2"
  grep -a -q -F "$s" "$f" 2>/dev/null
}

for f in \
  "$WASMVM_OUT"/libwasmvm_muslc.x86_64.a \
  "$WASMVM_OUT"/libwasmvm_muslc.aarch64.a
do
  [ -f "$f" ] || continue
  if ! has_sym "$f" store_code_with_circuit; then
    err "$(basename "$f") missing store_code_with_circuit (not a ZK muslc)"
  else
    note "OK $(basename "$f") store_code_with_circuit"
  fi
  if ! has_sym "$f" verify_stwo_host_proof; then
    err "$(basename "$f") missing verify_stwo_host_proof (stale muslc vs Go bindings)"
  fi
done

dylibs=0
for f in \
  "$WASMVM_OUT"/libwasmvm.dylib \
  "$WASMVM_OUT"/libwasmvm.x86_64.so \
  "$WASMVM_OUT"/libwasmvm.aarch64.so \
  "$WASMVM_OUT"/libwasmvmstatic_darwin.a
do
  [ -f "$f" ] && dylibs=$((dylibs + 1))
done
note "wasmvm dylibs/archives present: $dylibs (+ muslc if staged)"

# ------------------------------------------------------------------
# ELF + Cosmovisor tarballs
# ------------------------------------------------------------------
present_elf=()
for arch in amd64 arm64; do
  elf="$BUILD_DIR/terpd-linux-$arch"
  [ -f "$elf" ] || continue
  tar_this="$BUILD_DIR/terpd-${VER}-linux-$arch.tar.gz"
  if [ ! -f "$tar_this" ] && [ "$ALLOW_PARTIAL" = "1" ]; then
    wrn "$elf has no $tar_this — leftover from another tag, skipped"
    continue
  fi
  present_elf+=("$arch")
  info="$(file "$elf")"
  echo "  $elf: $info"
  case "$arch" in
    amd64) echo "$info" | grep -E "ELF 64-bit LSB executable, x86-64" >/dev/null || err "$elf is not linux/amd64 ELF" ;;
    arm64) echo "$info" | grep -Ei "ELF 64-bit LSB executable, ARM aarch64" >/dev/null || err "$elf is not linux/arm64 ELF" ;;
  esac
  echo "$info" | grep -i "statically linked" >/dev/null || wrn "$elf is not statically linked"
  if ! has_sym "$elf" store_code_with_circuit; then
    err "$elf missing store_code_with_circuit"
  else
    note "OK terpd-linux-$arch store_code_with_circuit"
  fi
  if ! has_sym "$elf" verify_stwo_host_proof; then
    err "$elf missing verify_stwo_host_proof (linked stale muslc)"
  fi
done

if [ "${#present_elf[@]}" -eq 0 ]; then
  wrn "no $BUILD_DIR/terpd-linux-{amd64,arm64} — soak must set RELEASE_ELF or build-reproducible"
elif [ "${#present_elf[@]}" -lt 2 ] && [ "$ALLOW_PARTIAL" != "1" ]; then
  err "both linux amd64 and arm64 ELFs required (ALLOW_PARTIAL=0)"
fi

tar_ok=()
sums_tmp="$(mktemp)"
trap 'rm -f "$sums_tmp"' EXIT

for arch_os in linux-amd64 linux-arm64 darwin-arm64; do
  tar="$BUILD_DIR/terpd-${VER}-${arch_os}.tar.gz"
  [ -f "$tar" ] || continue
  members="$(tar tzf "$tar")"
  # Cosmovisor extracts DAEMON_NAME at archive root.
  if ! printf '%s\n' "$members" | grep -qx 'terpd' && ! printf '%s\n' "$members" | grep -qx './terpd'; then
    err "$tar has no root member terpd (got: $(printf '%s' "$members" | tr '\n' ' '))"
    continue
  fi
  extra="$(printf '%s\n' "$members" | grep -v -x -e 'terpd' -e './terpd' -e '.' || true)"
  if [ -n "$extra" ]; then
    wrn "$tar extra members: $(printf '%s' "$extra" | tr '\n' ' ')"
  fi
  sum="$(sha256_file "$tar")"
  echo "$sum  $(basename "$tar")" >> "$sums_tmp"
  tar_ok+=("$arch_os")
  note "OK $(basename "$tar") member=terpd sha256=$sum"
done

if [ "${#tar_ok[@]}" -eq 0 ]; then
  wrn "no Cosmovisor tarballs build/terpd-${VER}-*.tar.gz — run: ALLOW_PARTIAL=1 make release-prep RELEASE_TAG=$TAG"
fi

# ------------------------------------------------------------------
# cosmovisor.json: reject file:// / \$HOME; rewrite from real checksums
# ------------------------------------------------------------------
cvj="$PACK/cosmovisor.json"
if [ "$WRITE" != "1" ] && [ -f "$cvj" ]; then
  if grep -E 'file://|\$HOME|\$\{HOME\}' "$cvj" >/dev/null; then
    err "$cvj uses file:// or unexpanded \$HOME — Cosmovisor cannot download that (WRITE=1 to rebuild from tarballs)"
  fi
  if grep -v checksum=sha256: "$cvj" | grep -q 'https://' ; then
    wrn "$cvj has a URL without ?checksum=sha256:"
  fi
fi

if [ "$WRITE" = "1" ]; then
  mkdir -p "$PACK"
  if [ ! -s "$sums_tmp" ]; then
    wrn "WRITE=1 but no versioned tarballs for $TAG — skipped cosmovisor.json rewrite"
  else
    python3 "$ROOT/scripts/release/create_binaries_json/create_binaries_json.py" \
      --tag "$TAG" \
      --checksums_file "$sums_tmp" \
      --out "$cvj"
    note "wrote $cvj"
    cat "$cvj"
    if [ -f "$PACK/draft_proposal.json" ] && command -v jq >/dev/null; then
      compact="$(jq -c . "$cvj")"
      tmp_prop="$(mktemp)"
      jq --arg info "$compact" '.messages[0].plan.info=$info' "$PACK/draft_proposal.json" > "$tmp_prop"
      mv "$tmp_prop" "$PACK/draft_proposal.json"
      note "draft_proposal plan.info is compact Cosmovisor binaries JSON"
    fi
    {
      echo "plan: $PLAN"
      echo "binary_tag: $TAG"
      echo "binary_commit: $(git rev-parse HEAD)"
      echo "dirty: $(git describe --tags --always --dirty)"
      echo "s3_binaries_intended: $S3_BASE/"
      echo "published: false"
      echo "note: checksums are of local tarballs; do not upload until asked."
      if [ -s "$sums_tmp" ]; then
        echo
        cat "$sums_tmp"
      fi
      for arch in "${present_elf[@]+"${present_elf[@]}"}"; do
        echo "$(sha256_file "$BUILD_DIR/terpd-linux-$arch")  terpd-linux-$arch"
      done
    } > "$PACK/ARTIFACT_LOCK"
    note "wrote $PACK/ARTIFACT_LOCK"
  fi
fi

if [ -f "$cvj" ]; then
  if grep -E 'file://|\$HOME' "$cvj" >/dev/null; then
    : # already counted
  elif ! grep -q checksum=sha256: "$cvj"; then
    wrn "$cvj has no checksum=sha256: entries — pre-place upgrades/${PLAN}/bin/terpd and leave DAEMON_ALLOW_DOWNLOAD_BINARIES=false"
  else
    note "OK $cvj has checksummed download URLs"
  fi
fi

echo
if [ "$fail" -ne 0 ]; then
  echo "=== preflight FAILED ===" >&2
  exit 1
fi
echo "=== preflight OK ($warn warning(s)) ==="
