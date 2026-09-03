#!/usr/bin/env bash
# Pack a terpd ELF as a Cosmovisor tarball (member must be `terpd`).
#   ./scripts/release/pack_cv_tarball.sh build/terpd-linux-amd64 build/terpd-6.2.0-dev-linux-amd64.tar.gz
set -euo pipefail
src="${1:?elf}"
dest="${2:?tarball}"
[ -f "$src" ] || { echo "missing $src"; exit 1; }
stage="$(mktemp -d)"
cp "$src" "$stage/terpd"
chmod 755 "$stage/terpd"
mkdir -p "$(dirname "$dest")"
COPYFILE_DISABLE=1 tar -C "$stage" -czf "$dest" terpd
rm -rf "$stage"
members="$(tar tzf "$dest")"
printf '%s\n' "$members" | grep -qx 'terpd' || printf '%s\n' "$members" | grep -qx './terpd' || {
  echo "ERROR: $dest missing root member terpd (got $members)" >&2
  exit 1
}
if command -v sha256sum >/dev/null; then
  echo "$(sha256sum "$dest")"
else
  echo "$(shasum -a 256 "$dest")"
fi
