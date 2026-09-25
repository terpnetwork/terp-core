#!/usr/bin/env bash
# Host entry: bit-for-bit recurate of any vX.Y.Z tag on a fresh guest.
# Guests: firecracker (KVM Linux), wasmer (WASMER_SSH Linux or wasmer CLI), local.
# Dual: GUESTS=firecracker,wasmer  (both must match S3 and each other).
# Version extras: releases/<tag>.sh (historical; do not edit published tags).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
if [ ! -f "$ROOT/scripts/release/fetch_zk_muslc.sh" ]; then
  echo "ERROR: ROOT=$ROOT is not the terp-core checkout" >&2
  exit 2
fi
TAG="${TAG:-}"
if [ -z "$TAG" ] || ! echo "$TAG" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "ERROR: set TAG=vX.Y.Z" >&2
  exit 2
fi
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64,darwin/arm64}"
S3_BASE="${S3_BASE:-https://s3.terp.network/releases/terp-core/${TAG}}"
GIT_REMOTE="${GIT_REMOTE:-https://github.com/terpnetwork/terp-core.git}"
VERSION_SCRIPT="$HERE/releases/${TAG}.sh"
STAGE="${FRESH_VM_STAGE:-/tmp/terp-fresh-toolkit-${TAG}}"
REMOTE_TOOLKIT="${FRESH_VM_REMOTE_TOOLKIT:-/tmp/terp-fresh}"
WASMER_BIN="${WASMER_BIN:-wasmer}"

pack_toolkit() {
  if [ "${PACKED:-0}" = 1 ]; then
    return 0
  fi
  rm -rf "$STAGE"
  mkdir -p "$STAGE/releases" "$STAGE/extras" "$STAGE/out"
  cp "$HERE/guest.sh" "$STAGE/guest.sh"
  cp "$HERE/releases/"*.sh "$STAGE/releases/" 2>/dev/null || true
  cp "$HERE/releases/README.md" "$STAGE/releases/" 2>/dev/null || true
  cp "$ROOT/scripts/release/fetch_zk_muslc.sh" "$STAGE/fetch_zk_muslc.sh"
  if [ -f "$VERSION_SCRIPT" ]; then
    echo "==> version extras $VERSION_SCRIPT"
    # shellcheck source=/dev/null
    export HOST_ROOT="$ROOT"
    source "$VERSION_SCRIPT"
    if declare -F fresh_vm_host_stage >/dev/null; then
      fresh_vm_host_stage "$STAGE/extras"
    fi
  else
    echo "NOTE: no $VERSION_SCRIPT — default prepare only"
  fi
  PACKED=1
}

run_guest_local() {
  local toolkit="$1"
  FRESH_VM=1 \
    FRESH_VM_GUEST="${FRESH_VM_GUEST:-local}" \
    FRESH_VM_TOOLKIT="$toolkit" \
    FRESH_VM_EXTRAS="$toolkit/extras" \
    TAG="$TAG" \
    PLATFORMS="$PLATFORMS" \
    GIT_REMOTE="$GIT_REMOTE" \
    S3_BASE="$S3_BASE" \
    bash "$toolkit/guest.sh"
}

save_guest_sums() {
  local label="$1"
  mkdir -p "$STAGE/out"
  if [ -f "$STAGE/rebuilt.sha256sum.txt" ]; then
    cp "$STAGE/rebuilt.sha256sum.txt" "$STAGE/out/${label}.sha256sum.txt"
    echo "==> stored $STAGE/out/${label}.sha256sum.txt"
  fi
}

run_via_ssh() {
  local host="$1"
  local label="$2"
  pack_toolkit || return 1
  echo "==> $label SSH $host"
  ssh -o StrictHostKeyChecking=accept-new "$host" \
    "mkdir -p $REMOTE_TOOLKIT && command -v git && command -v docker && command -v curl" \
    || return 1
  if command -v rsync >/dev/null; then
    rsync -a -e ssh "$STAGE/" "$host:$REMOTE_TOOLKIT/" || return 1
  else
    tar -C "$STAGE" -czf - . | ssh "$host" "mkdir -p $REMOTE_TOOLKIT && tar -C $REMOTE_TOOLKIT -xzf -" \
      || return 1
  fi
  ssh "$host" \
    "FRESH_VM=1 FRESH_VM_GUEST=$label FRESH_VM_TOOLKIT=$REMOTE_TOOLKIT FRESH_VM_EXTRAS=$REMOTE_TOOLKIT/extras TAG=$TAG PLATFORMS=$PLATFORMS GIT_REMOTE=$GIT_REMOTE S3_BASE=$S3_BASE bash $REMOTE_TOOLKIT/guest.sh" \
    || return 1
  scp -o StrictHostKeyChecking=accept-new \
    "$host:$REMOTE_TOOLKIT/rebuilt.sha256sum.txt" "$STAGE/out/${label}.sha256sum.txt" 2>/dev/null \
    || echo "NOTE: no rebuilt.sha256sum.txt from $label"
}

run_via_wasmer_cli() {
  if ! command -v "$WASMER_BIN" >/dev/null; then
    echo "ERROR: wasmer CLI not found. Install: curl https://get.wasmer.io -sSfL | sh" >&2
    echo "  Linux muslc recurate needs git+docker+make: set WASMER_SSH=user@linux instead." >&2
    return 2
  fi
  local pkg="${WASMER_PACKAGE:-}"
  if [ -z "$pkg" ]; then
    echo "ERROR: GUEST=wasmer without WASMER_SSH needs WASMER_PACKAGE (Wasmer Registry / .webc)." >&2
    echo "  WASIX packages do not include Docker; for linux ELFs use WASMER_SSH to a Linux host." >&2
    return 2
  fi
  pack_toolkit || return 1
  echo "==> wasmer run $pkg (WASIX; docker muslc only if this package provides docker)"
  # shellcheck disable=SC2086
  "$WASMER_BIN" run "$pkg" --net --http-client \
    --volume "$STAGE:/fresh" \
    --env FRESH_VM=1 \
    --env FRESH_VM_GUEST=wasmer \
    --env FRESH_VM_TOOLKIT=/fresh \
    --env FRESH_VM_EXTRAS=/fresh/extras \
    --env TAG="$TAG" \
    --env PLATFORMS="$PLATFORMS" \
    --env GIT_REMOTE="$GIT_REMOTE" \
    --env S3_BASE="$S3_BASE" \
    ${WASMER_RUN_ARGS:-} \
    -- /fresh/guest.sh || return 1
  if [ -f "$STAGE/rebuilt.sha256sum.txt" ]; then
    cp "$STAGE/rebuilt.sha256sum.txt" "$STAGE/out/wasmer.sha256sum.txt"
  fi
}

dispatch_guest() {
  local kind="$1"
  echo "=== guest backend $kind TAG=$TAG ==="
  case "$kind" in
    firecracker)
      if [ -n "${FIRECRACKER_SSH:-}" ]; then
        run_via_ssh "$FIRECRACKER_SSH" firecracker
        return
      fi
      if command -v firecracker >/dev/null && [ -n "${FC_KERNEL:-}" ] && [ -n "${FC_ROOTFS:-}" ]; then
        echo "ERROR: local firecracker+kernel+rootfs present but run.sh does not boot the VM." >&2
        echo "Boot a Linux microVM, then: FRESH_VM=1 TAG=$TAG $0" >&2
        echo "Or: FIRECRACKER_SSH=user@microvm TAG=$TAG $0" >&2
        return 2
      fi
      echo "ERROR: GUEST=firecracker requires FIRECRACKER_SSH=user@microvm" >&2
      return 2
      ;;
    wasmer)
      if [ -n "${WASMER_SSH:-}" ]; then
        run_via_ssh "$WASMER_SSH" wasmer
        return
      fi
      run_via_wasmer_cli
      ;;
    local)
      pack_toolkit || return 1
      echo "==> local throwaway clone + empty GOMODCACHE on $(uname -s)/$(uname -m)"
      FRESH_VM_GUEST=local run_guest_local "$STAGE" || return 1
      save_guest_sums local
      ;;
    *)
      echo "ERROR: unknown GUEST=$kind (firecracker|wasmer|local)" >&2
      return 2
      ;;
  esac
}

cross_check_guests() {
  local n=0 f a b hash name other
  for f in "$STAGE/out"/*.sha256sum.txt; do
    [ -f "$f" ] || continue
    n=$((n + 1))
  done
  if [ "$n" -lt 2 ]; then
    echo "NOTE: $n guest hash file(s) in $STAGE/out — skip cross-guest compare"
    return 0
  fi
  local xc=0
  for a in "$STAGE/out"/*.sha256sum.txt; do
    [ -f "$a" ] || continue
    for b in "$STAGE/out"/*.sha256sum.txt; do
      [ -f "$b" ] || continue
      [ "$a" = "$b" ] && continue
      case "$a" in
        "$b") continue ;;
      esac
      [ "$a" \< "$b" ] || continue
      echo "==> cross-check $(basename "$a") vs $(basename "$b")"
      while read -r hash name; do
        [ -n "${name:-}" ] || continue
        other=$(awk -v n="$name" '$2==n {print $1; exit}' "$b")
        if [ -z "$other" ]; then
          echo "NOTE: $name only in $(basename "$a")"
          continue
        fi
        if [ "$hash" != "$other" ]; then
          echo "ERROR: $name $(basename "$a")=$hash $(basename "$b")=$other" >&2
          xc=1
        else
          echo "OK $name both guests $hash"
        fi
      done < "$a"
    done
  done
  [ "$xc" = 0 ]
}

# Already inside a guest (Firecracker/Wasmer SSH payload).
if [ "${FRESH_VM:-0}" = "1" ]; then
  run_guest_local "$HERE"
  exit $?
fi

GUESTS="${GUESTS:-}"
GUEST="${GUEST:-}"
if [ -z "$GUESTS" ]; then
  if [ -n "$GUEST" ]; then
    GUESTS="$GUEST"
  elif [ -n "${FIRECRACKER_SSH:-}" ] && [ -n "${WASMER_SSH:-}" ]; then
    GUESTS="firecracker,wasmer"
  elif [ -n "${FIRECRACKER_SSH:-}" ]; then
    GUESTS="firecracker"
  elif [ -n "${WASMER_SSH:-}" ]; then
    GUESTS="wasmer"
  else
    GUESTS="local"
  fi
fi

echo "==> guests: $GUESTS"
fail=0
old_ifs=$IFS
IFS=,
# shellcheck disable=SC2086
set -- $GUESTS
IFS=$old_ifs
for kind in "$@"; do
  kind=$(echo "$kind" | tr -d ' ')
  [ -n "$kind" ] || continue
  st=0
  dispatch_guest "$kind" || st=$?
  if [ "$st" -eq 2 ]; then
    echo "ERROR: guest $kind is not configured" >&2
    exit 2
  fi
  if [ "$st" -ne 0 ]; then
    echo "ERROR: guest $kind failed" >&2
    fail=1
  fi
done
if ! cross_check_guests; then
  fail=1
fi
if [ "$fail" -ne 0 ]; then
  echo "=== FAIL TAG=$TAG guests=$GUESTS ===" >&2
  exit 1
fi
echo "=== OK TAG=$TAG guests=$GUESTS ==="
