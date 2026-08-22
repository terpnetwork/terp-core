#!/usr/bin/env bash
# Assert a just-built terpd is bit-identical to the prebuilt used for E2E.
# Usage: assert-identical.sh <prebuilt-terpd> <rebuilt-terpd>
set -euo pipefail
A="${1:?prebuilt terpd}"
B="${2:?rebuilt terpd}"
test -f "$A" && test -f "$B"
ha="$(sha256sum "$A" | awk '{print $1}')"
hb="$(sha256sum "$B" | awk '{print $1}')"
echo "prebuilt $ha  $A"
echo "rebuilt  $hb  $B"
if [ "$ha" != "$hb" ]; then
  echo "ERROR: rebuilt terpd does not match prebuilt (not the same bits)" >&2
  exit 1
fi
echo "identical"
