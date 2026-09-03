#!/usr/bin/env bash
# Validate published terp-core artifacts using existing tsh/ict scripts.
# Never compiles. Points NEW_BIND / docker image at S3 bits.
#
#   RELEASE_TAG=v6.0.0 ./scripts/release/verify_artifacts.sh
# Skip: SKIP_ICT=1 SKIP_TSH=1 SKIP_IMAGE=1
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
TAG="${RELEASE_TAG:-v6.0.0}"
DEST="${DEST:-/tmp/terp-release-$TAG}"
MUSLC_BASE="${MUSLC_BASE:-https://minio.terp.network/releases/zk-wasmvm/v3.0.7-zk}"
export PATH="/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:${PATH}"

if [ "${LOCAL:-0}" = "1" ]; then
  echo "=== verify_artifacts LOCAL $TAG ==="
  PLAN="${PLAN:-v6.1}" TAG="$TAG" ALLOW_PARTIAL="${ALLOW_PARTIAL:-1}" \
    bash "$ROOT/scripts/release/preflight_upgrade.sh"
  echo "=== verify_artifacts LOCAL $TAG OK ==="
  exit 0
fi

echo "=== verify_artifacts $TAG ==="

echo "==> 1 fetch"
bash "$ROOT/scripts/release/fetch_release_artifacts.sh" "$TAG" "$DEST"

echo "==> 2 sha256 vs published sha256sum.txt"
(
  cd "$DEST"
  : > /tmp/verify-present.txt
  awk '{print $2}' sha256sum.txt | while read -r f; do
    if [ -f "$f" ]; then echo "$f" >> /tmp/verify-present.txt; fi
  done
  grep -F -f /tmp/verify-present.txt sha256sum.txt > /tmp/verify.sums
  shasum -a 256 -c /tmp/verify.sums
)
got_amd64="$(shasum -a 256 "$DEST/terpd-linux-amd64" | awk '{print $1}')"
echo "terpd-linux-amd64 $got_amd64"

echo "==> 3 muslc (MinIO, else local wasmvm-release)"
if curl -fsSL -o /tmp/SHA256SUMS.muslc "$MUSLC_BASE/SHA256SUMS"; then
  cat /tmp/SHA256SUMS.muslc
  mkdir -p /tmp/muslc-check
  curl -fsSL -o /tmp/muslc-check/libwasmvm_muslc.x86_64.a "$MUSLC_BASE/libwasmvm_muslc.x86_64.a"
  curl -fsSL -o /tmp/muslc-check/libwasmvm_muslc.aarch64.a "$MUSLC_BASE/libwasmvm_muslc.aarch64.a"
  (cd /tmp/muslc-check && shasum -a 256 -c /tmp/SHA256SUMS.muslc)
elif [ -f "$ROOT/build/wasmvm-release/SHA256SUMS" ]; then
  echo "MinIO muslc not published; checking local build/wasmvm-release"
  (cd "$ROOT/build/wasmvm-release" && shasum -a 256 -c SHA256SUMS)
else
  echo "ERROR: muslc not at $MUSLC_BASE and no build/wasmvm-release" >&2
  exit 1
fi

echo "==> 4 ELF / ZK symbols"
info="$(file "$DEST/terpd-linux-amd64")"
echo "$info"
echo "$info" | grep -E "ELF 64-bit LSB executable, x86-64" >/dev/null
echo "$info" | grep -i "statically linked" >/dev/null
grep -a -q -F store_code_with_circuit "$DEST/terpd-linux-amd64"
echo "ok store_code_with_circuit"
if grep -a -q -F verify_stwo_host_proof "$DEST/terpd-linux-amd64"; then
  echo "ok verify_stwo_host_proof"
else
  echo "ERROR: verify_stwo_host_proof not in ELF (stale muslc vs Go bindings)" >&2
  exit 1
fi

if [ "${SKIP_IMAGE:-0}" != "1" ] && [ -f "$DEST/terp-core-local-linux-amd64.tar" ]; then
  echo "==> 5 docker load; image terpd == S3 ELF"
  want_img="$(awk '{print $1}' "$DEST/terp-core-local-linux-amd64.tar.sha256")"
  got_img="$(shasum -a 256 "$DEST/terp-core-local-linux-amd64.tar" | awk '{print $1}')"
  if [ "$want_img" != "$got_img" ]; then
    echo "ERROR: image tar $got_img != $want_img" >&2
    exit 1
  fi
  docker load -i "$DEST/terp-core-local-linux-amd64.tar"
  docker image inspect terpnetwork/terp-core:local >/dev/null
  docker rm -f v6-verify-img 2>/dev/null || true
  docker create --name v6-verify-img terpnetwork/terp-core:local >/dev/null
  docker cp v6-verify-img:/usr/local/bin/terpd /tmp/v6-verify-img-terpd
  docker rm -f v6-verify-img >/dev/null
  bash "$ROOT/scripts/ci/assert-identical.sh" "$DEST/terpd-linux-amd64" /tmp/v6-verify-img-terpd
else
  echo "==> 5 skip image"
fi

if [ "${SKIP_ICT:-0}" != "1" ]; then
  echo "==> 6 ict-rs against published image"
  bash "$ROOT/scripts/ci/fetch-ict-rs-bins.sh" /tmp/ict-bins
  run_ict() {
    docker run --rm --platform linux/amd64 \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v /tmp/ict-bins:/ict:ro \
      -v "$ROOT":/src:ro \
      -e TERP_CORE=/src \
      -e TERP_IMAGE_REPO=terpnetwork/terp-core \
      -e TERP_IMAGE_VERSION=local \
      -e ICT_CI_BIN_DIR=/ict/examples \
      -w /src \
      ubuntu:24.04 \
      bash -lc "/ict/ict-ci run $1"
  }
  run_ict ibc_transfer
  if [ -f artifacts/polytone_note.wasm ]; then
    run_ict polytone
  fi
else
  echo "==> 6 skip ict"
fi

if [ "${SKIP_TSH:-0}" = "1" ]; then
  echo "==> 7 skip tsh"
elif [ "$(uname -s)" != "Linux" ]; then
  echo "==> 7 tsh skipped: linux ELF cannot exec on $(uname -s)/$(uname -m)"
  echo "    linux: SKIP_INSTALL=1 NEW_BIND=$DEST/terpd-linux-amd64 make tsh-upgrade-wasm tsh-upgrade-cv"
else
  echo "==> 7 tsh d.sh + e.sh"
  command -v terp-mainnet >/dev/null || { echo "terp-mainnet not on PATH"; exit 1; }
  SKIP_INSTALL=1 NEW_BIND="$DEST/terpd-linux-amd64" OLD_BIND=terp-mainnet \
    bash tests/tsh/upgrade/d.sh
  SKIP_INSTALL=1 NEW_BIND="$DEST/terpd-linux-amd64" OLD_BIND=terp-mainnet \
    bash tests/tsh/upgrade/e.sh
fi

echo "=== verify_artifacts $TAG OK ==="
