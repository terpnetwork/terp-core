#!/usr/bin/env bash
# Query every module params surface after a v6.1 upgrade.
# Must run against a live NEW_BIND node (a.sh / v61.sh leave it up).
#
# Fails if any query errors — that is the signal that a leftover x/params
# value was not copied into its module store.
set -euo pipefail

NEW_BIND="${NEW_BIND:-terpd}"
VAL1HOME="${VAL1HOME:?VAL1HOME is required}"
VAL1_RPC_PORT="${VAL1_RPC_PORT:-26657}"
NODE="tcp://127.0.0.1:${VAL1_RPC_PORT}"

q() {
  local name="$1"
  shift
  local out rc
  set +e
  # --home first so client.toml (node=) is loaded. SDK 0.55 --node is per-subcommand.
  out=$("$NEW_BIND" --home "$VAL1HOME" q "$@" --output json 2>&1)
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "FAIL params query: $name"
    echo "$out"
    return 1
  fi
  if echo "$out" | jq -e . >/dev/null 2>&1; then
    echo "ok  $name"
    return 0
  fi
  # ibchooks wasm-sender prints a bech32, not JSON.
  if echo "$out" | grep -qE '^terp1[0-9a-z]+$'; then
    echo "ok  $name"
    return 0
  fi
  echo "FAIL params query not JSON: $name"
  echo "$out"
  return 1
}

echo "query-all-params: node=$NODE home=$VAL1HOME"
fail=0

# SDK modules (params live in each module store since v0.47; still must query).
q auth auth params || fail=1
q bank bank params || fail=1
q staking staking params || fail=1
q mint mint params || fail=1
q distribution distribution params || fail=1
q slashing slashing params || fail=1
q gov gov params || fail=1
q consensus consensus params || fail=1
q wasm wasm params || fail=1

# IBC
q ibc-transfer ibc-transfer params || fail=1
if "$NEW_BIND" --home "$VAL1HOME" q interchain-accounts host --help >/dev/null 2>&1; then
  q ica-host interchain-accounts host params || fail=1
fi
if "$NEW_BIND" --home "$VAL1HOME" q interchain-accounts controller --help >/dev/null 2>&1; then
  q ica-controller interchain-accounts controller params || fail=1
fi
# packet-forward has no standalone `q … params` command in this binary.

# Custom modules that still had x/params subspaces on morocco-1.
q tokenfactory tokenfactory params || fail=1
q feeshare feeshare params || fail=1
q globalfee globalfee minimum-gas-prices || fail=1
q smartaccount smartaccount params || fail=1
q drip drip params || fail=1
q hashmerchant hashmerchant params || fail=1
q cw-hooks cw-hooks params || fail=1

# Modules with no `q … params` (ibc-go v11 packet-forward GetQueryCmd is nil).
# Prove they are live via module-versions + a real query on the same stack.
echo "--- surfaces without q params ---"
set +e
mvjson=$("$NEW_BIND" --home "$VAL1HOME" q upgrade module-versions --output json 2>&1)
mrc=$?
set -e
if [ "$mrc" -ne 0 ] || ! echo "$mvjson" | jq -e . >/dev/null 2>&1; then
  echo "FAIL module-versions"
  echo "$mvjson"
  fail=1
else
  echo "ok  upgrade module-versions"
  for need in packetfowardmiddleware wasm ibchooks transfer interchainaccounts hashmerchant feeshare tokenfactory smartaccount globalfee staking auth; do
    if echo "$mvjson" | jq -e --arg n "$need" '[.module_versions[]? | .name] | index($n) != null' >/dev/null; then
      echo "ok  module-version $need"
    else
      echo "FAIL module-version missing $need"
      fail=1
    fi
  done
  # SDK 0.55 migrations
  stver=$(echo "$mvjson" | jq -r '.module_versions[] | select(.name=="staking") | .version')
  auver=$(echo "$mvjson" | jq -r '.module_versions[] | select(.name=="auth") | .version')
  echo "ok  staking consensus version=$stver (want 6)"
  echo "ok  auth consensus version=$auver (want 7)"
  [ "$stver" = "6" ] || { echo "FAIL staking version $stver"; fail=1; }
  [ "$auver" = "7" ] || { echo "FAIL auth version $auver"; fail=1; }
fi

q ibc-client-params ibc client params || fail=1
q ibc-connection-params ibc connection params || fail=1
q ibc-client-states ibc client states || fail=1
q ibc-wasm-checksums ibc-wasm checksums || fail=1
q evidence-list evidence list || fail=1
q wasm-list-code wasm list-code || fail=1
q wasm-pinned wasm pinned || fail=1

# ibchooks: local address derivation (does not need a live packet).
HOOKS_SENDER="${HOOKS_SENDER:-terp10d07y265gmmuvt4z0w9aw880jnsr700jag6fuq}"
q ibchooks-wasm-sender ibchooks wasm-sender channel-0 "$HOOKS_SENDER" || fail=1

if [ "$fail" -ne 0 ]; then
  echo "query-all-params: one or more module queries failed"
  exit 1
fi
echo "query-all-params: all module params + non-params surfaces succeeded"
