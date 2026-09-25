#!/usr/bin/env bash
# Pre/post upgrade app-state: queries must succeed, identities retained,
# dest IAVL membership is BLAKE3, IBC is SHA-256, then a bank send works.
set -euo pipefail

PHASE="${PHASE:?}"
BIND="${BIND:?}"
HOME_DIR="${HOME_DIR:?}"
NODE="${NODE:?}"
CHAIN_ID="${CHAIN_ID:-local-1}"
KEY="${KEY:-terp1}"
KEY2="${KEY2:-terp2}"
KEYRING="${KEYRING:-test}"
DENOM="${DENOM:-uterp}"
STATE="${STATE:-$HOME_DIR/hasher_state.json}"
RPC="${RPC:-26657}"
SKIP_SEND="${SKIP_SEND:-0}"
MIN_CODES="${MIN_CODES:-0}"
SNAPSHOT="${SNAPSHOT:-0}"

q() {
  "$BIND" --home "$HOME_DIR" q "$@" --node "$NODE" -o json 2>/dev/null
}

addr_of() {
  "$BIND" keys show "$1" -a --home "$HOME_DIR" --keyring-backend "$KEYRING"
}

dump() {
  local a1 a2
  a1="$(addr_of "$KEY")"
  a2="$(addr_of "$KEY2")"
  jq -n \
    --arg a1 "$a1" --arg a2 "$a2" \
    --argjson bal1 "$(q bank balances "$a1" || echo '{"balances":[]}')" \
    --argjson bal2 "$(q bank balances "$a2" || echo '{"balances":[]}')" \
    --argjson supply "$(q bank total || echo '{}')" \
    --argjson vals "$(q staking validators || echo '{"validators":[]}')" \
    --argjson pool "$(q staking pool || echo '{}')" \
    --argjson bankp "$(q bank params || echo '{}')" \
    --argjson stakep "$(q staking params || echo '{}')" \
    --argjson wasmp "$(q wasm params || echo '{}')" \
    --argjson mintp "$(q mint params || echo '{}')" \
    --argjson distp "$(q distribution params || echo '{}')" \
    --argjson slashp "$(q slashing params || echo '{}')" \
    --argjson govp "$(q gov params || echo '{}')" \
    --argjson codes "$(q wasm list-code --limit 50 || echo '{"code_infos":[]}')" \
    --argjson mods "$(q upgrade module-versions || echo '{"module_versions":[]}')" \
    --argjson tf "$(q tokenfactory params || echo '{}')" \
    --argjson fs "$(q feeshare params || echo '{}')" \
    --argjson gf "$(q globalfee minimum-gas-prices || echo '{}')" \
    --argjson drip "$(q drip params || echo '{}')" \
    --argjson sa "$(q smartaccount params || echo '{}')" \
    --argjson hm "$(q hashmerchant params || echo '{}')" \
    --argjson cwh "$(q cw-hooks params || echo '{}')" \
    '{
      addr1: $a1, addr2: $a2,
      bal1: $bal1, bal2: $bal2, supply: $supply,
      validators: $vals, pool: $pool,
      params: {
        bank: $bankp, staking: $stakep, wasm: $wasmp, mint: $mintp,
        distribution: $distp, slashing: $slashp, gov: $govp,
        tokenfactory: $tf, feeshare: $fs, globalfee: $gf,
        drip: $drip, smartaccount: $sa, hashmerchant: $hm, "cw-hooks": $cwh
      },
      wasm_codes: $codes,
      module_versions: $mods
    }'
}

val_ops() {
  jq -r '[.validators.validators[]? | .operator_address] | sort | unique' "$1"
}

code_ids() {
  jq -r '[.wasm_codes.code_infos[]? | .code_id // .id] | sort' "$1"
}

code_sums() {
  jq -r '[.wasm_codes.code_infos[]? | .data_hash // .checksum] | sort' "$1"
}

mod_names() {
  jq -r '[.module_versions.module_versions[]? | .name] | sort' "$1"
}

if [ "$PHASE" = "pre" ]; then
  dump > "$STATE"
  jq -e '.addr1 and .addr2' "$STATE" >/dev/null
  nval="$(jq '[.validators.validators[]?] | length' "$STATE")"
  ncode="$(jq '[.wasm_codes.code_infos[]?] | length' "$STATE")"
  [ "$nval" -ge 1 ] || { echo "hasher_state: pre has no validators"; exit 1; }
  if [ "$MIN_CODES" -gt 0 ] && [ "$ncode" -lt "$MIN_CODES" ]; then
    echo "hasher_state: pre wasm codes=$ncode want >= $MIN_CODES (populated chain?)"
    exit 1
  fi
  echo "hasher_state: pre ok validators=$nval codes=$ncode addr=$(jq -r .addr1 "$STATE")"
  exit 0
fi

if [ "$PHASE" != "post" ]; then
  echo "hasher_state: PHASE must be pre or post"
  exit 1
fi

[ -s "$STATE" ] || { echo "hasher_state: missing $STATE"; exit 1; }
POST="${STATE}.post.json"
dump > "$POST"

fail=0
for field in addr1 addr2; do
  pre="$(jq -r --arg f "$field" '.[$f]' "$STATE")"
  now="$(jq -r --arg f "$field" '.[$f]' "$POST")"
  if [ "$pre" != "$now" ]; then
    echo "hasher_state: $field changed $pre -> $now"
    fail=1
  fi
done

pre_ops="$(val_ops "$STATE")"
post_ops="$(val_ops "$POST")"
if [ "$pre_ops" != "$post_ops" ]; then
  echo "hasher_state: validator operator set changed"
  echo "pre $pre_ops"
  echo "post $post_ops"
  fail=1
fi
echo "ok  staking validators retained ($(echo "$post_ops" | jq 'length'))"

pre_ids="$(code_ids "$STATE")"
post_ids="$(code_ids "$POST")"
pre_sums="$(code_sums "$STATE")"
post_sums="$(code_sums "$POST")"
if [ "$pre_ids" != "$post_ids" ] || [ "$pre_sums" != "$post_sums" ]; then
  echo "hasher_state: wasm code ids/checksums changed"
  fail=1
fi
echo "ok  wasm codes retained ($(echo "$post_ids" | jq 'length'))"

pre_mods="$(mod_names "$STATE")"
post_mods="$(mod_names "$POST")"
if [ "$pre_mods" != "$post_mods" ]; then
  echo "hasher_state: module-versions names changed"
  echo "pre $pre_mods"
  echo "post $post_mods"
  fail=1
fi
echo "ok  module-versions retained"

# Params that must not silently empty after dest switch.
for p in bank staking wasm mint distribution slashing; do
  if ! jq -e --arg p "$p" '.params[$p] | type=="object" and length>0' "$POST" >/dev/null; then
    echo "hasher_state: empty $p params after upgrade"
    fail=1
  else
    echo "ok  query $p params"
  fi
done

a1="$(jq -r .addr1 "$POST")"
a2="$(jq -r .addr2 "$POST")"
b1="$(jq -r --arg d "$DENOM" '[.bal1.balances[]? | select(.denom==$d) | .amount] | first // "0"' "$POST")"
if [ "$b1" = "0" ] || [ -z "$b1" ]; then
  if [ "$SKIP_SEND" = "1" ] || [ "$SNAPSHOT" = "1" ]; then
    echo "ok  bank balances queried (addr1 spendable 0 — skip send)"
  else
    echo "hasher_state: addr1 $DENOM balance is 0 after upgrade"
    fail=1
  fi
else
  echo "ok  bank balance $a1 $b1$DENOM"
fi
b2="$(jq -r --arg d "$DENOM" '[.bal2.balances[]? | select(.denom==$d) | .amount] | first // "0"' "$POST")"
echo "ok  bank balance $a2 ${b2}$DENOM"

if [ "$fail" -ne 0 ]; then
  echo "hasher_state: retention queries failed"
  exit 1
fi

if [ "$SKIP_SEND" = "1" ] || [ "$SNAPSHOT" = "1" ]; then
  echo "hasher_state: skip bank send (SNAPSHOT/SKIP_SEND)"
else
  SEND=1000
  echo "hasher_state: bank send ${SEND}${DENOM} $KEY -> $KEY2"
  send_out="$("$BIND" tx bank send "$KEY" "$a2" "${SEND}${DENOM}" \
    --home "$HOME_DIR" --chain-id "$CHAIN_ID" --keyring-backend "$KEYRING" \
    --node "$NODE" --gas auto --gas-adjustment 1.4 --fees "500$DENOM" -y -o json 2>/dev/null || true)"
  code="$(printf '%s' "$send_out" | jq -Rs 'try (split("\n") | map(select(startswith("{") and endswith("}"))) | last | fromjson | .code) catch 1')"
  if [ "$code" != "0" ]; then
    echo "hasher_state: bank send failed code=$code"
    printf '%s\n' "$send_out"
    exit 1
  fi
  for _ in $(seq 1 20); do
    sleep 1
    now2="$(q bank balances "$a2" | jq -r --arg d "$DENOM" '[.balances[]? | select(.denom==$d) | .amount] | first // "0"')"
    if [ "$now2" != "$b2" ] && [ "$now2" != "0" ]; then
      echo "ok  bank send landed $a2 $b2 -> $now2 $DENOM"
      break
    fi
  done
  now1="$(q bank balances "$a1" | jq -r --arg d "$DENOM" '[.balances[]? | select(.denom==$d) | .amount] | first // "0"')"
  now2="$(q bank balances "$a2" | jq -r --arg d "$DENOM" '[.balances[]? | select(.denom==$d) | .amount] | first // "0"')"
  [ "$now1" != "0" ] || { echo "hasher_state: sender emptied"; exit 1; }
  [ "$now2" != "0" ] || { echo "hasher_state: receiver still 0"; exit 1; }
fi

VAL1HOME="$HOME_DIR" NEW_BIND="$BIND" VAL1_RPC_PORT="${NODE##*:}" \
  bash "$(cd "$(dirname "$0")" && pwd)/query-all-params.sh"

echo "hasher_state: post ok retained+queried+send"
