#!/usr/bin/env bash
# Pack a terpd ELF as a Cosmovisor tarball (member must be `terpd`).
# SOURCE_DATE_EPOCH (unix) + gzip -n so recurate matches the lock.
#   ./scripts/release/pack_cv_tarball.sh build/terpd-linux-amd64 build/terpd-6.4.0-linux-amd64.tar.gz
set -euo pipefail
src="${1:?elf}"
dest="${2:?tarball}"
[ -f "$src" ] || { echo "missing $src"; exit 1; }
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp "$src" "$stage/terpd"
chmod 755 "$stage/terpd"
epoch="${SOURCE_DATE_EPOCH:-0}"
if date -u -r "$epoch" +%Y%m%d%H%M.%S >/dev/null 2>&1; then
  ts="$(date -u -r "$epoch" +%Y%m%d%H%M.%S)"
else
  ts="$(date -u -d "@$epoch" +%Y%m%d%H%M.%S)"
fi
TZ=UTC touch -t "$ts" "$stage/terpd"
mkdir -p "$(dirname "$dest")"
COPYFILE_DISABLE=1 tar -C "$stage" -cf - terpd | gzip -n > "$dest"
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
