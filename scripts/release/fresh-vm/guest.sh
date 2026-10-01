#!/usr/bin/env bash
# Guest payload: clone TAG into empty GOPATH, run version extras, rebuild, compare S3.
set -euo pipefail

_here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOOLKIT="${FRESH_VM_TOOLKIT:-$_here}"
EXTRAS="${FRESH_VM_EXTRAS:-$TOOLKIT/extras}"
TAG="${TAG:-}"
if [ -z "$TAG" ] || ! echo "$TAG" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "ERROR: set TAG=vX.Y.Z" >&2
  exit 2
fi
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64,darwin/arm64}"
S3_BASE="${S3_BASE:-https://s3.terp.network/releases/terp-core/${TAG}}"
GIT_REMOTE="${GIT_REMOTE:-https://github.com/terpnetwork/terp-core.git}"
WORK="${FRESH_WORK:-/tmp/terp-fresh-${TAG}}"
VERSION_SCRIPT="$TOOLKIT/releases/${TAG}.sh"
export PATH="/usr/local/go/bin:/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:${PATH}"

sha256_file() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

want_platform() {
  echo ",$PLATFORMS," | grep -q ",$1,"
}

copy_tree() {
  mkdir -p "$2"
  if command -v rsync >/dev/null; then
    rsync -a --exclude='.git/' "$1/" "$2/"
  else
    mkdir -p "$2"
    cp -R "$1/." "$2/"
  fi
}

fetch_ibc_hooks() {
  grep -q '=> ./crates/ibc-hooks-v11' go.mod || return 0
  [ -f crates/ibc-hooks-v11/go.mod ] && { echo "OK ibc-hooks-v11 already present"; return 0; }
  local url="${IBC_HOOKS_URL:-https://minio.terp.network/releases/terp-core/v6.0.0-dev/ibc-hooks-v11.tar.gz}"
  local want="${IBC_HOOKS_SHA256:-1b31faa98bedb7e388eef97ed031143a851b0d8a799b52d7b1b3ab78c898a312}"
  local tar="$WORK/ibc-hooks-v11.tar.gz"
  echo "==> fetch ibc-hooks-v11 $url"
  curl -fsSL -o "$tar" "$url"
  local got
  got="$(sha256_file "$tar")"
  if [ "$got" != "$want" ]; then
    echo "ERROR: ibc-hooks-v11.tar.gz sha256=$got want=$want" >&2
    exit 1
  fi
  mkdir -p crates
  tar -C crates -xzf "$tar"
  test -f crates/ibc-hooks-v11/go.mod
  echo "OK ibc-hooks-v11 $got"
}

rebuild_muslc() {
  command -v docker >/dev/null || { echo "ERROR: docker required to rebuild muslc" >&2; exit 1; }
  local builders="crates/zk-wasmvm/builders"
  local df="$builders/Dockerfile.alpine"
  if [ -f "$builders/Dockerfile.alpine-nightly" ]; then
    df="$builders/Dockerfile.alpine-nightly"
    echo "==> muslc Dockerfile.alpine-nightly (terpnetwork/zk-alpine-builder, not CosmWasm 0103)"
  fi
  [ -f "$df" ] || { echo "ERROR: missing $df" >&2; exit 1; }
  local tmp="$WORK/Dockerfile.alpine"
  if [ -n "${FRESH_VM_BUILDER_FROM:-}" ]; then
    sed -E "s|^(FROM --platform=linux/amd64) rust:[^[:space:]]+|\\1 ${FRESH_VM_BUILDER_FROM}|" "$df" > "$tmp"
    echo "==> muslc builder FROM ${FRESH_VM_BUILDER_FROM}"
  else
    cp "$df" "$tmp"
  fi
  echo "==> rebuild muslc builder image (docker build --no-cache --pull)"
  docker build --no-cache --pull -t terp-fresh-muslc-builder -f "$tmp" "$builders"
  if [ ! -d crates/zcash ]; then
    mkdir -p "$WORK/empty-zcash"
    export ZK_ZCASH_DIR="$WORK/empty-zcash"
  fi
  echo "==> cargo muslc aarch64+x86_64 inside rebuilt builder"
  ( cd crates/zk-wasmvm && BUILDER_IMAGE=terp-fresh-muslc-builder make release-build-alpine-custom )
  local arch name want got
  for arch in aarch64 x86_64; do
    name="crates/zk-wasmvm/internal/api/libwasmvm_muslc.${arch}.a"
    [ -f "$name" ] || { echo "ERROR: muslc rebuild missing $name" >&2; exit 1; }
    grep -a -q -F 'stwo: Dummy DSTW rejected' "$name" \
      || { echo "ERROR: $name missing Path A STWO host" >&2; exit 1; }
    got="$(sha256_file "$name")"
    echo "rebuilt $name $got"
    if [ "$arch" = aarch64 ]; then
      want="${WASMVM_MUSLC_AARCH64_SHA:-}"
    else
      want="${WASMVM_MUSLC_X86_SHA:-}"
    fi
    if [ -n "$want" ] && [ "$got" != "$want" ]; then
      echo "ERROR: rebuilt muslc ${arch} $got != published pin $want" >&2
      if [ "${FRESH_VM_ALLOW_MUSLC_DRIFT:-0}" != 1 ]; then
        echo "  set FRESH_VM_ALLOW_MUSLC_DRIFT=1 to continue (terpd will likely miss S3)" >&2
        exit 1
      fi
    elif [ -n "$want" ]; then
      echo "OK muslc ${arch} matches published pin"
    fi
  done
}

fetch_muslc() {
  if [ -f "$TOOLKIT/fetch_zk_muslc.sh" ]; then
    bash "$TOOLKIT/fetch_zk_muslc.sh" crates/zk-wasmvm/internal/api
  elif [ -f scripts/release/fetch_zk_muslc.sh ]; then
    bash scripts/release/fetch_zk_muslc.sh crates/zk-wasmvm/internal/api
  else
    echo "ERROR: fetch_zk_muslc.sh missing and WASMVM_MUSLC_FETCH=1" >&2
    exit 1
  fi
}

rebuild_darwin_a() {
  [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || return 0
  want_platform darwin/arm64 || return 0
  [ -f crates/zk-wasmvm/builders/host/build_macos_static_arm64.sh ] || return 0
  echo "==> rebuild libwasmvmstatic_darwin.a from source"
  bash crates/zk-wasmvm/builders/host/build_macos_static_arm64.sh
}

default_prepare() {
  for p in crates/zk-wasmd crates/zk-wasmvm crates/cosmwasm; do
    if [ -f .gitmodules ] && grep -Fq "path = ${p}" .gitmodules; then
      git submodule update --init --checkout "$p"
    fi
  done
  fetch_ibc_hooks
  if want_platform linux/amd64 || want_platform linux/arm64; then
    if [ "${WASMVM_MUSLC_FETCH:-0}" = 1 ]; then
      echo "NOTE: WASMVM_MUSLC_FETCH=1 — linking published muslc, not rebuilding Rust"
      fetch_muslc
    else
      rebuild_muslc
    fi
  fi
  rebuild_darwin_a
}

apply_extras() {
  [ -d "$EXTRAS/crates" ] || return 0
  for d in "$EXTRAS/crates"/*; do
    [ -d "$d" ] || continue
    dest="crates/$(basename "$d")"
    mkdir -p "$dest"
    copy_tree "$d" "$dest"
    echo "OK extras $(basename "$d") -> $dest"
  done
}

require_local_replaces() {
  local paths
  paths="$(awk '
    $1=="replace" && $2!="(" {
      for (i=1;i<=NF;i++) if ($i=="=>") { t=$(i+1); if (t ~ /^\.\//) print t }
    }
    /^replace \(/ {inrep=1; next}
    inrep && /^\)/ {inrep=0; next}
    inrep {
      for (i=1;i<=NF;i++) if ($i=="=>") { t=$(i+1); if (t ~ /^\.\//) print t }
    }
  ' go.mod)"
  local p miss=0
  for p in $paths; do
    if [ ! -e "$p" ]; then
      echo "ERROR: go.mod replace target missing: $p" >&2
      echo "  ibc-hooks-v11: set IBC_HOOKS_URL + IBC_HOOKS_SHA256 (guest fetches; do not copy from a laptop)" >&2
      miss=1
    fi
  done
  [ "$miss" = 0 ] || exit 1
}

echo "=== fresh recurate TAG=$TAG GUEST=${FRESH_VM_GUEST:-?} WORK=$WORK ==="
if [ -d "$WORK" ]; then
  chmod -R u+w "$WORK" 2>/dev/null || true
  rm -rf "$WORK" || { echo "ERROR: cannot clear $WORK (try a new FRESH_WORK=)" >&2; exit 1; }
fi
mkdir -p "$WORK"
git clone --branch "$TAG" --single-branch "$GIT_REMOTE" "$WORK/src"
cd "$WORK/src"
COMMIT="$(git rev-parse HEAD)"
echo "commit $COMMIT ($(git describe --tags --always))"

export GOPATH="$WORK/go"
export GOMODCACHE="$WORK/gocache"
export GOCACHE="$WORK/gocache-build"
export GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
mkdir -p "$GOPATH" "$GOMODCACHE" "$GOCACHE"
if [ "$GOMODCACHE" = "$HOME/go/pkg/mod" ]; then
  echo "ERROR: GOMODCACHE still host cache $GOMODCACHE" >&2
  exit 1
fi

if [ "${BUILDX_NO_CACHE:-1}" = 1 ]; then
  mkdir -p "$WORK/bin"
  REAL_DOCKER="$(command -v docker || true)"
  if [ -n "$REAL_DOCKER" ]; then
    cat > "$WORK/bin/docker" <<WRAP
#!/bin/sh
if [ "\$1" = buildx ] && [ "\$2" = build ]; then
  shift 2
  exec $REAL_DOCKER buildx build --no-cache "\$@"
fi
exec $REAL_DOCKER "\$@"
WRAP
    chmod +x "$WORK/bin/docker"
    export PATH="$WORK/bin:$PATH"
  fi
fi

if [ -f "$VERSION_SCRIPT" ]; then
  # shellcheck source=/dev/null
  source "$VERSION_SCRIPT"
fi
if declare -F fresh_vm_prepare >/dev/null; then
  fresh_vm_prepare
else
  default_prepare
fi
apply_extras
require_local_replaces

curl -fsSL -o "$WORK/published.sha256sum.txt" "$S3_BASE/sha256sum.txt"
echo "==> published $S3_BASE/sha256sum.txt"
cat "$WORK/published.sha256sum.txt"

fail=0
compare_one() {
  local name="$1"
  local file="$2"
  [ -f "$file" ] || { echo "ERROR: missing rebuilt $file" >&2; fail=1; return; }
  local got want
  got="$(sha256_file "$file")"
  want="$(awk -v n="$name" '$2==n {print $1; exit}' "$WORK/published.sha256sum.txt")"
  echo "rebuilt $name $got"
  if [ -z "$want" ]; then
    echo "ERROR: $name not in published sha256sum.txt" >&2
    fail=1
    return
  fi
  if [ "$got" != "$want" ]; then
    echo "ERROR: $name rebuilt $got != published $want" >&2
    fail=1
  else
    echo "OK $name matches S3"
  fi
}

export WASMVM_SOURCE=local
export RELEASE_TAG="$TAG"
export GIT_VERSION="$TAG"
export GIT_COMMIT="$COMMIT"
# Dual tags on one SHA: stamp VERSION from TAG, not git describe.
export VERSION="${TAG#v}"
# v6.4.0 extras set BUILD_TAGS=v64; docker linux ELF always includes muslc.
if [ "$TAG" = "v6.4.0" ]; then
  export BUILD_TAGS="${BUILD_TAGS:-v64}"
fi

if want_platform linux/amd64 || want_platform linux/arm64; then
  command -v docker >/dev/null || { echo "ERROR: docker required for linux ELFs" >&2; exit 1; }
  export BUILDX_NO_CACHE="${BUILDX_NO_CACHE:-1}"
  if want_platform linux/amd64; then
    echo "==> linux/amd64 (docker buildx --no-cache, empty GOMODCACHE)"
    DOCKER_BUILDKIT=1 $(command -v make) build-reproducible-amd64 VERSION="$VERSION" BUILD_TAGS="${BUILD_TAGS:-}"
    compare_one terpd-linux-amd64 build/terpd-linux-amd64
  fi
  if want_platform linux/arm64; then
    echo "==> linux/arm64 (docker buildx --no-cache, empty GOMODCACHE)"
    DOCKER_BUILDKIT=1 $(command -v make) build-reproducible-arm64 VERSION="$VERSION" BUILD_TAGS="${BUILD_TAGS:-}"
    compare_one terpd-linux-arm64 build/terpd-linux-arm64
  fi
fi

if want_platform darwin/arm64; then
  if [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ]; then
    echo "==> darwin/arm64 host rebuild (empty GOMODCACHE)"
    if [ ! -f crates/zk-wasmvm/internal/api/libwasmvmstatic_darwin.a ]; then
      echo "NOTE: no libwasmvmstatic_darwin.a in clone/extras — skip darwin rebuild"
      if grep -q 'terpd-darwin-arm64' "$WORK/published.sha256sum.txt"; then
        echo "published darwin hash: $(awk '$2=="terpd-darwin-arm64"{print $1}' "$WORK/published.sha256sum.txt")"
      fi
    else
      bash scripts/release/build_host_darwin.sh
      compare_one terpd-darwin-arm64 build/terpd-darwin-arm64
    fi
  else
    echo "NOTE: darwin/arm64 skipped (Linux guest cannot produce Mach-O)"
    if grep -q 'terpd-darwin-arm64' "$WORK/published.sha256sum.txt"; then
      echo "published darwin hash: $(awk '$2=="terpd-darwin-arm64"{print $1}' "$WORK/published.sha256sum.txt")"
    fi
  fi
fi

write_rebuilt_sums() {
  local out="$WORK/rebuilt.sha256sum.txt"
  : > "$out"
  local name
  for name in terpd-linux-amd64 terpd-linux-arm64 terpd-darwin-arm64; do
    [ -f "build/$name" ] || continue
    echo "$(sha256_file "build/$name")  $name" >> "$out"
  done
  cp "$out" "$TOOLKIT/rebuilt.sha256sum.txt"
  echo "==> rebuilt sums ($TOOLKIT/rebuilt.sha256sum.txt)"
  cat "$out"
}

write_rebuilt_sums

if declare -F fresh_vm_verify >/dev/null; then
  fresh_vm_verify
fi

if [ "$fail" -ne 0 ]; then
  echo "=== FAIL TAG=$TAG GUEST=${FRESH_VM_GUEST:-?} (see ERROR lines) ===" >&2
  exit 1
fi
echo "=== OK TAG=$TAG GUEST=${FRESH_VM_GUEST:-?} bit-for-bit vs $S3_BASE/sha256sum.txt ==="
