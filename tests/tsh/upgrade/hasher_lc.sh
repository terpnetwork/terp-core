#!/usr/bin/env bash
# Counterparty 08-wasm LC — same lifecycle as hasher_ibc_bench A→C:
#   gzip + tx ibc-wasm store-code (gov) on chain2
#   tx ibc client create /ibc.lightclients.wasm.v1.ClientState (lab JSON inner)
#   cw-ics08-wasm-terp VerifyMembership of chain1 dest-bank (BLAKE3 inner nodes)
#   and ibc (SHA-256). RecvPacket is not this proof: hybrid ibc stays SHA-256.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../../.." && pwd)"
BIND="${BIND:-terpd}"
VERIFY_BIND="${VERIFY_BIND:-$BIND}"
HOME1="${HOME1:?}"
HOME2="${HOME2:?}"
ID1="${ID1:-local-1}"
ID2="${ID2:-local-2}"
RPC1="${RPC1:-26657}"
RPC2="${RPC2:-27657}"
P2P2="${P2P2:-27656}"
GRPC2="${GRPC2:-9190}"
LC_LOG="${LC_LOG:-$HOME2/hasher-lc.log}"
KEY="${KEY:-terp1}"
KEYRING="${KEYRING:-test}"
DENOM="${DENOM:-uterp}"
WASM_LC="${WASM_LC:-$REPO/crates/terp-rs/artifacts/cw_ics08_wasm_terp.wasm}"

mkdir -p "$(dirname "$LC_LOG")"
: > "$LC_LOG"

rpc() { curl -sf "http://127.0.0.1:$1/status"; }
wait_rpc() {
  local port=$1
  for _ in $(seq 1 60); do curl -sf "http://127.0.0.1:$port/status" >/dev/null && return 0; sleep 1; done
  return 1
}
wait_first_block() {
  local port=$1
  for _ in $(seq 1 30); do
    local h
    h="$(curl -sf "http://127.0.0.1:$port/status" | jq -r '.result.sync_info.latest_block_height // "0"')"
    if [ "${h:-0}" -ge 2 ] 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}
wait_tx() {
  local hash=$1
  local raw=""
  for _ in $(seq 1 30); do
    raw="$("$BIND" q tx "$hash" --home "$HOME2" --node "tcp://127.0.0.1:${RPC2}" -o json 2>/dev/null || true)"
    local h code
    h="$(printf '%s' "$raw" | jq -r '.height // "0"' 2>/dev/null || echo 0)"
    code="$(printf '%s' "$raw" | jq -r '.code // 1' 2>/dev/null || echo 1)"
    if [ "${h:-0}" != "0" ] && [ -n "$h" ] && [ "$h" != "null" ]; then
      printf '%s\n' "$raw" >> "$LC_LOG"
      if [ "$code" != "0" ]; then
        echo "hasher_lc: tx $hash code=$code" | tee -a "$LC_LOG"
        return 1
      fi
      printf '%s' "$raw"
      return 0
    fi
    sleep 1
  done
  echo "hasher_lc: tx $hash not included" | tee -a "$LC_LOG"
  return 1
}
txhash_from() {
  printf '%s' "$1" | grep -Eo '"txhash"[[:space:]]*:[[:space:]]*"[A-Fa-f0-9]+"' | head -1 | grep -Eo '[A-Fa-f0-9]{64}'
}
cleanup_chain2() {
  local pid
  pid="$(cat "$HOME2/node.pid" 2>/dev/null || true)"
  if [ -n "${pid:-}" ]; then
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$HOME2/node.pid"
}
trap cleanup_chain2 EXIT

if [ ! -s "$WASM_LC" ]; then
  echo "hasher_lc: missing $WASM_LC" | tee -a "$LC_LOG"
  exit 1
fi

if [ ! -d "$HOME2/config" ]; then
  echo "decorate bright ozone fork gallery riot bus exhaust worth way bone indoor calm squirrel merry zero scheme cotton until shop any excess stage laundry" | \
    "$BIND" keys add "$KEY" --home "$HOME2" --keyring-backend "$KEYRING" --recover >/dev/null
  "$BIND" init localterp --home "$HOME2" --chain-id "$ID2" --default-denom "$DENOM"
  jq '.app_state.gov.params.voting_period="8s" | .app_state.gov.params.expedited_voting_period="4s" | .app_state.gov.params.min_deposit=[{"denom":"uterp","amount":"1000000"}] | .app_state.staking.params.bond_denom="uterp" | .app_state.mint.params.mint_denom="uterp"' \
    "$HOME2/config/genesis.json" > "$HOME2/config/tmp.json"
  mv "$HOME2/config/tmp.json" "$HOME2/config/genesis.json"
  "$BIND" genesis add-genesis-account "$KEY" 1000000000000uterp --home "$HOME2" --keyring-backend "$KEYRING"
  "$BIND" genesis gentx "$KEY" 10000000000uterp --home "$HOME2" --keyring-backend "$KEYRING" --chain-id "$ID2"
  "$BIND" genesis collect-gentxs --home "$HOME2"
fi

sed -i.bak "/^\[rpc\]/,/^\[/ s/^laddr *=.*/laddr = \"tcp:\/\/127.0.0.1:${RPC2}\"/" "$HOME2/config/config.toml"
sed -i.bak "/^\[rpc\]/,/^\[/ s/^pprof_laddr *=.*/pprof_laddr = \"localhost:16062\"/" "$HOME2/config/config.toml"
sed -i.bak "/^\[p2p\]/,/^\[/ s/^laddr *=.*/laddr = \"tcp:\/\/127.0.0.1:${P2P2}\"/" "$HOME2/config/config.toml"
sed -i.bak "/^\[grpc\]/,/^\[/ s/address.*/address = \"localhost:${GRPC2}\"/" "$HOME2/config/app.toml" || true
sed -i.bak "/^\[consensus\]/,/^\[/ s/^[[:space:]]*timeout_commit[[:space:]]*=.*/timeout_commit = \"1s\"/" "$HOME2/config/config.toml"

: > "$HOME2/node.log"
"$BIND" start --home "$HOME2" --pruning=nothing --minimum-gas-prices=0uterp \
  --rpc.laddr="tcp://127.0.0.1:${RPC2}" ${WASMVM_SKIP:+--wasm.skip_wasmvm_version_check} >>"$HOME2/node.log" 2>&1 &
echo $! > "$HOME2/node.pid"
if ! wait_rpc "$RPC2"; then
  echo "hasher_lc: chain2 RPC failed" | tee -a "$LC_LOG"
  tail -40 "$HOME2/node.log" >> "$LC_LOG" || true
  exit 1
fi
if ! wait_first_block "$RPC2"; then
  echo "hasher_lc: chain2 produced no block" | tee -a "$LC_LOG"
  tail -40 "$HOME2/node.log" >> "$LC_LOG" || true
  exit 1
fi
echo "hasher_lc: chain2 height=$(curl -sf "http://127.0.0.1:${RPC2}/status" | jq -r '.result.sync_info.latest_block_height')" | tee -a "$LC_LOG"

GZ="$HOME2/cw_ics08_wasm_terp.wasm.gz"
gzip -c -9 "$WASM_LC" > "$GZ"
echo "hasher_lc: storing 08-wasm LC $WASM_LC (gzip $(wc -c < "$GZ") bytes) on $ID2" | tee -a "$LC_LOG"
store_out="$("$BIND" tx ibc-wasm store-code "$GZ" \
  --title "cw-ics08-wasm-terp" --summary "Terp IAVL 08-wasm LC" \
  --deposit "1000000uterp" --from "$KEY" --home "$HOME2" --chain-id "$ID2" \
  --keyring-backend "$KEYRING" --node "tcp://127.0.0.1:${RPC2}" \
  --gas auto --gas-adjustment 1.5 --fees "2000uterp" -y -o json 2>>"$LC_LOG")"
printf '%s\n' "$store_out" >> "$LC_LOG"
STORE_HASH="$(txhash_from "$store_out")"
if [ -z "$STORE_HASH" ]; then
  echo "hasher_lc: store-code missing txhash" | tee -a "$LC_LOG"
  exit 1
fi
store_tx="$(wait_tx "$STORE_HASH")" || exit 1
PROP="$(printf '%s' "$store_tx" | jq -r '[.events[]?.attributes[]? | select((.key=="proposal_id") or (.key=="proposal-id")) | .value] | first // empty')"
PROP="${PROP:-1}"
echo "hasher_lc: store-code included hash=$STORE_HASH proposal=$PROP" | tee -a "$LC_LOG"
vote_out="$("$BIND" tx gov vote "$PROP" yes --from "$KEY" --home "$HOME2" --chain-id "$ID2" \
  --keyring-backend "$KEYRING" --node "tcp://127.0.0.1:${RPC2}" \
  --gas auto --gas-adjustment 1.2 --fees "1000uterp" -y -o json 2>>"$LC_LOG")"
printf '%s\n' "$vote_out" >> "$LC_LOG"
VOTE_HASH="$(txhash_from "$vote_out")"
if [ -n "$VOTE_HASH" ]; then
  wait_tx "$VOTE_HASH" >/dev/null || exit 1
fi
passed=0
for i in $(seq 1 40); do
  st="$("$BIND" q gov proposal "$PROP" --node "tcp://127.0.0.1:${RPC2}" -o json 2>/dev/null || true)"
  echo "$st" | jq -r '.status // .proposal.status // empty' >> "$LC_LOG" || true
  if printf '%s' "$st" | grep -q 'PROPOSAL_STATUS_PASSED'; then
    passed=1
    break
  fi
  sleep 1
done
if [ "$passed" != "1" ]; then
  echo "hasher_lc: gov proposal $PROP did not pass" | tee -a "$LC_LOG"
  exit 1
fi
CS=""
for i in $(seq 1 20); do
  raw="$("$BIND" q ibc-wasm checksums --node "tcp://127.0.0.1:${RPC2}" -o json 2>/dev/null || true)"
  CS="$(printf '%s' "$raw" | jq -r '
    .checksums[0] as $c
    | if $c == null then empty
      elif ($c | type) == "string" then $c
      else ($c.checksum // empty)
      end
  ' 2>/dev/null || true)"
  if [ -n "$CS" ] && [ "$CS" != "null" ]; then
    echo "hasher_lc: 08-wasm checksums on $ID2 cs=$CS" | tee -a "$LC_LOG"
    printf '%s\n' "$raw" | tee -a "$LC_LOG"
    break
  fi
  sleep 1
done
if [ -z "$CS" ] || [ "$CS" = "null" ]; then
  echo "hasher_lc: ibc-wasm store-code did not produce checksums" | tee -a "$LC_LOG"
  tail -60 "$HOME2/node.log" >> "$LC_LOG" || true
  exit 1
fi

ST="$(rpc "$RPC1")"
H="$(printf '%s' "$ST" | jq -r '.result.sync_info.latest_block_height')"
APP_B64="$(printf '%s' "$ST" | jq -r '.result.sync_info.latest_app_hash')"
if [ -z "$H" ] || [ "$H" = "null" ] || [ -z "$APP_B64" ] || [ "$APP_B64" = "null" ]; then
  echo "hasher_lc: missing chain1 status for CreateClient" | tee -a "$LC_LOG"
  exit 1
fi

python3 - "$CS" "$H" "$ID1" "$APP_B64" "$HOME2" <<'PY' | tee -a "$LC_LOG"
import base64, json, sys, pathlib
cs_raw, height, chain_id, app_b64, dest = sys.argv[1:6]
raw = cs_raw.strip().removeprefix("0x")
try:
    checksum = bytes.fromhex(raw)
except ValueError:
    checksum = base64.b64decode(raw)
if len(checksum) != 32:
    raise SystemExit(f"checksum want 32 bytes, got {len(checksum)}")
s = app_b64.strip().removeprefix("0x")
app = b""
if len(s) == 64 and all(c in "0123456789abcdefABCDEF" for c in s):
    app = bytes.fromhex(s)
else:
    try:
        app = base64.b64decode(s)
    except Exception:
        app = b""
    if len(app) != 32 and all(c in "0123456789abcdefABCDEF" for c in s) and len(s) % 2 == 0:
        app = bytes.fromhex(s)
if len(app) != 32:
    raise SystemExit(f"app hash want 32 bytes, got {len(app)}")
inner_cs = json.dumps({
    "chain_id": chain_id,
    "latest_height": {"revision_number": 0, "revision_height": int(height)},
    "hasher_mode": "auto",
    "frozen": False,
}).encode()
inner_cons = json.dumps({
    "timestamp_ns": 1_000_000_000,
    "root_hex": app.hex(),
}).encode()
cs = {
    "@type": "/ibc.lightclients.wasm.v1.ClientState",
    "data": base64.b64encode(inner_cs).decode(),
    "checksum": base64.b64encode(checksum).decode(),
    "latest_height": {"revision_number": "0", "revision_height": str(height)},
}
cons = {
    "@type": "/ibc.lightclients.wasm.v1.ConsensusState",
    "data": base64.b64encode(inner_cons).decode(),
}
path = pathlib.Path(dest)
(path / "wasm_cs.json").write_text(json.dumps(cs))
(path / "wasm_cons.json").write_text(json.dumps(cons))
print(f"hasher_lc: wrote wasm client JSON height={height} checksum={checksum.hex()} apphash={app.hex()}")
PY

echo "hasher_lc: CreateClient 08-wasm on $ID2 of $ID1 (lab JSON, hasher_mode=auto)" | tee -a "$LC_LOG"
"$BIND" tx ibc client create "$HOME2/wasm_cs.json" "$HOME2/wasm_cons.json" \
  --from "$KEY" --home "$HOME2" --chain-id "$ID2" \
  --keyring-backend "$KEYRING" --node "tcp://127.0.0.1:${RPC2}" \
  --gas auto --gas-adjustment 2.5 --fees "5000uterp" -y -o json >>"$LC_LOG" 2>&1
sleep 2
CLIENT=""
for i in $(seq 1 20); do
  raw="$("$BIND" q ibc client states --node "tcp://127.0.0.1:${RPC2}" -o json 2>/dev/null || true)"
  CLIENT="$(printf '%s' "$raw" | jq -r '[.client_states[]?.client_id // .clients[]?.client_id // empty] | map(select(startswith("08-wasm"))) | .[0] // empty' 2>/dev/null || true)"
  if [ -n "$CLIENT" ]; then
    echo "hasher_lc: 08-wasm client on $ID2: $CLIENT" | tee -a "$LC_LOG"
    "$BIND" q ibc client state "$CLIENT" --node "tcp://127.0.0.1:${RPC2}" -o json 2>/dev/null | tee -a "$LC_LOG" || true
    break
  fi
  sleep 1
done
if [ -z "$CLIENT" ]; then
  echo "hasher_lc: CreateClient did not produce 08-wasm-* on $ID2" | tee -a "$LC_LOG"
  tail -80 "$HOME2/node.log" >> "$LC_LOG" || true
  exit 1
fi

echo "hasher_lc: 08-wasm LC VerifyMembership of $ID1 dest-bank BLAKE3 + ibc SHA-256" | tee -a "$LC_LOG"
out="$("$VERIFY_BIND" debug wasm-lc-verify \
  --node "tcp://127.0.0.1:${RPC1}" --home "$HOME1" \
  --wasm "$WASM_LC" --bank-store b3-bank --ibc-store ibc 2>&1)" || {
  echo "$out" | tee -a "$LC_LOG"
  echo "hasher_lc: wasm-lc-verify failed" | tee -a "$LC_LOG"
  exit 1
}
echo "$out" | tee -a "$LC_LOG"
echo "$out" | grep -q "OK wasm-lc bank=blake3 ibc=sha256"

echo "hasher_lc: OK 08-wasm LC inclusion proofs bank=blake3 ibc=sha256 client=$CLIENT" | tee -a "$LC_LOG"
