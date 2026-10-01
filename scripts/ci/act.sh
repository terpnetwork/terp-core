#!/usr/bin/env bash
# Run nektos/act on this machine's architecture and always remove its containers.
#
#   ./scripts/ci/act.sh workflow_dispatch -W .github/workflows/act-soundness.yml
#   ACT_PLATFORM=linux/amd64 ./scripts/ci/act.sh -l
#
# groot2 is linux/amd64. This Mac is linux/arm64. Do not force the other arch:
# qemu is how act jobs die on missing binaries.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

arch="$(uname -m)"
case "${ACT_PLATFORM:-}" in
  linux/amd64|linux/arm64) platform="$ACT_PLATFORM" ;;
  "")
    case "$arch" in
      x86_64|amd64) platform=linux/amd64 ;;
      arm64|aarch64) platform=linux/arm64 ;;
      *)
        echo "ERROR: unknown arch $arch. Set ACT_PLATFORM=linux/amd64 or linux/arm64." >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "ERROR: ACT_PLATFORM must be linux/amd64 or linux/arm64 (got ${ACT_PLATFORM})." >&2
    exit 1
    ;;
esac

command -v act >/dev/null || { echo "ERROR: act is not on PATH" >&2; exit 1; }
command -v docker >/dev/null || { echo "ERROR: docker is not on PATH" >&2; exit 1; }

# nektos/act labels its containers. Names also start with act-.
act_teardown() {
  local ids
  ids="$(docker ps -aq --filter label=org.nektos.act 2>/dev/null || true)"
  if [ -z "$ids" ]; then
    ids="$(docker ps -aq --filter name=^act- 2>/dev/null || true)"
  fi
  if [ -n "$ids" ]; then
    # shellcheck disable=SC2086
    docker rm -f $ids >/dev/null 2>&1 || true
    echo "==> removed act containers"
  fi
}
trap act_teardown EXIT INT TERM

echo "==> act platform=$platform host=$arch"
# Do not exec. The EXIT trap has to run after act returns.
# --rm is act's own cleanup. The trap covers a killed run.
# One image tag. --container-architecture selects the manifest for this host.
# --bind keeps this checkout (and its .git) instead of a copy that is not a repo.
act --rm --bind --container-architecture "$platform" \
  -P "ubuntu-latest=catthehacker/ubuntu:act-latest" \
  "$@"
