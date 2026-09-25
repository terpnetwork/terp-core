#!/usr/bin/env bash
# ICS-23 IAVL light-client membership: dest bank BLAKE3, ibc SHA-256.
set -euo pipefail
BIND="${BIND:-terpd}"
NODE="${NODE:-tcp://127.0.0.1:26657}"
BANK_STORE="${BANK_STORE:-b3-bank}"
IBC_STORE="${IBC_STORE:-ibc}"
HOME_DIR="${HOME_DIR:-}"

extra=()
if [ -n "$HOME_DIR" ]; then
  extra+=(--home "$HOME_DIR")
fi

all_flags=()
if [ "${HASHER_ALL:-1}" = "1" ]; then
  all_flags+=(--all)
  if [ -n "${HASHER_REQUIRE:-}" ]; then
    all_flags+=(--require "$HASHER_REQUIRE")
  fi
fi
out="$("$BIND" debug hasher-proof --node "$NODE" --bank-store "$BANK_STORE" --ibc-store "$IBC_STORE" "${all_flags[@]}" "${extra[@]}" 2>&1)"
echo "$out"
echo "$out" | grep -q "OK hasher bank=blake3 ibc=sha256"
