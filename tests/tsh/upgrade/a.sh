#!/usr/bin/env bash
####################################################################
# TEST A: real upgrade workflow against morocco-1 appstate.
#
#   1. OLD_BIND (current mainnet, no v6 handler) loads appstate
#   2. OLD_BIND in-place-testnet --trigger-testnet-upgrade v6
#      produces blocks until plan height, then UPGRADE NEEDED + upgrade-info.json
#   3. NEW_BIND (this tree, v6 handler) starts on the same home
#   4. Require applied v6 and heights after the halt
#
#   OLD_BIND        default terp-mainnet for plan v6; v61.sh overrides to terpd-v6
#   NEW_BIND        default terpd         (make install of this tree)
#   STATE_SYNC=0    use SNAPSHOT_PATH (packed appstate)
#   STATE_SYNC=1    short-lived statesync on OLD_BIND, then isolate
####################################################################
set -euo pipefail

OLD_BIND="${OLD_BIND:-terp-mainnet}"
NEW_BIND="${NEW_BIND:-terpd}"
CHAINID="${CHAINID:-test-1}"
UPGRADE_VERSION="${UPGRADE_VERSION:-v6}"
NEW_RELEASE_PATH="${NEW_RELEASE_PATH:-../../../}"
STATE_SYNC="${STATE_SYNC:-1}"
RPC_SERVERS="${RPC_SERVERS:-https://rpc.terp.network:443,https://rpc.terp.network:443}"
STATUS_RPC="${STATUS_RPC:-https://rpc.terp.network}"
GENESIS_URL="${GENESIS_URL:-https://raw.githubusercontent.com/terpnetwork/networks/main/mainnet/morocco-1/genesis.json}"
SNAPSHOT_PATH="${SNAPSHOT_PATH:-../../../../../terp-snapshot-consensus-stall.tar.lz4}"
SNAPSHOT_URL="${SNAPSHOT_URL:-}"
CHAINDIR="${CHAINDIR:-./data}"
VAL1HOME="$CHAINDIR/$CHAINID/val1"
VAL1_API_PORT="${VAL1_API_PORT:-1317}"
VAL1_GRPC_PORT="${VAL1_GRPC_PORT:-9090}"
VAL1_RPC_PORT="${VAL1_RPC_PORT:-26657}"
VAL1_P2P_PORT="${VAL1_P2P_PORT:-26656}"
POST_BLOCKS="${POST_BLOCKS:-5}"
OLD_LOG="${OLD_LOG:-/tmp/tsh-a-old.log}"
NEW_LOG="${NEW_LOG:-/tmp/tsh-a-new.log}"

wait_rpc() {
  local url="http://127.0.0.1:${VAL1_RPC_PORT}/status"
  for _ in $(seq 1 180); do
    curl -sf "$url" >/dev/null 2>&1 && return 0
    sleep 2
  done
  echo "local RPC did not come up: $url"
  return 1
}

rpc_height() {
  curl -sf "http://127.0.0.1:${VAL1_RPC_PORT}/status" | jq -r '.result.sync_info.latest_block_height'
}

catching_up() {
  curl -sf "http://127.0.0.1:${VAL1_RPC_PORT}/status" | jq -r '.result.sync_info.catching_up'
}

query_bin() {
  if [ -x "$VAL1HOME/cosmovisor/current/bin/terpd" ]; then
    echo "$VAL1HOME/cosmovisor/current/bin/terpd"
  elif command -v "${NEW_BIND:-terpd}" >/dev/null; then
    command -v "$NEW_BIND"
  else
    command -v "$OLD_BIND"
  fi
}

# SDK returns { "height": "<halt>" } for a completed plan — no name field.
applied_height() {
  "$(query_bin)" q upgrade applied "$UPGRADE_VERSION" \
    --home "$VAL1HOME" \
    --node "tcp://127.0.0.1:${VAL1_RPC_PORT}" \
    -o json 2>/dev/null | jq -r '.height // empty'
}

configure_statesync() {
  local cfg="$VAL1HOME/config/config.toml"
  local latest trust_h trust_hash
  latest=$(curl -sf "${STATUS_RPC}/status" | jq -r '.result.sync_info.latest_block_height')
  trust_h=$((latest - 2000))
  if [ "$trust_h" -lt 1 ]; then
    echo "trust height underflow (latest=$latest)"
    exit 1
  fi
  trust_hash=$(curl -sf "${STATUS_RPC}/block?height=${trust_h}" | jq -r '.result.block_id.hash')
  if [ -z "$trust_hash" ] || [ "$trust_hash" = "null" ]; then
    echo "failed to fetch trust hash at $trust_h"
    exit 1
  fi
  echo "statesync trust_height=$trust_h trust_hash=$trust_hash rpc=$RPC_SERVERS"
  sed -i.bak "/^\[statesync\]/,/^\[/ s/^enable *=.*/enable = true/" "$cfg"
  sed -i.bak "/^\[statesync\]/,/^\[/ s|^rpc_servers *=.*|rpc_servers = \"$RPC_SERVERS\"|" "$cfg"
  sed -i.bak "/^\[statesync\]/,/^\[/ s/^trust_height *=.*/trust_height = $trust_h/" "$cfg"
  sed -i.bak "/^\[statesync\]/,/^\[/ s|^trust_hash *=.*|trust_hash = \"$trust_hash\"|" "$cfg"
  sed -i.bak "/^\[statesync\]/,/^\[/ s/^trust_period *=.*/trust_period = \"168h\"/" "$cfg"
}

isolate_p2p() {
  local cfg="$VAL1HOME/config/config.toml"
  sed -i.bak "/^\[rpc\]/,/^\[/ s/^laddr *=.*/laddr = \"tcp:\/\/127.0.0.1:$VAL1_RPC_PORT\"/" "$cfg"
  sed -i.bak "/^\[rpc\]/,/^\[/ s/^pprof_laddr *=.*/pprof_laddr = \"localhost:16060\"/" "$cfg"
  sed -i.bak "/^\[p2p\]/,/^\[/ s/^persistent_peers *=.*/persistent_peers = \"\"/" "$cfg"
  sed -i.bak "/^\[p2p\]/,/^\[/ s/^laddr *=.*/laddr = \"tcp:\/\/127.0.0.1:$VAL1_P2P_PORT\"/" "$cfg"
  sed -i.bak "/^\[p2p\]/,/^\[/ s/^pex *=.*/pex = false/" "$cfg"
  sed -i.bak "/^\[p2p\]/,/^\[/ s/^seeds *=.*/seeds = \"\"/" "$cfg"
  sed -i.bak "/^\[consensus\]/,/^\[/ s/^[[:space:]]*timeout_commit[[:space:]]*=.*/timeout_commit = \"1s\"/" "$cfg"
  sed -i.bak "/^\[api\]/,/^\[/ s/address.*/address = \"tcp:\/\/0.0.0.0:$VAL1_API_PORT\"/" "$VAL1HOME/config/app.toml" || true
  sed -i.bak "/^\[grpc\]/,/^\[/ s/address.*/address = \"localhost:$VAL1_GRPC_PORT\"/" "$VAL1HOME/config/app.toml" || true
}

command -v "$OLD_BIND" >/dev/null || { echo "$OLD_BIND not on PATH (v6.1: install v6 as terpd-v6)"; exit 1; }
echo "A: OLD_BIND=$OLD_BIND ($("$OLD_BIND" version 2>/dev/null | head -1))"
if [ "${CV_DOWNLOAD:-0}" = "1" ]; then
  echo "A: CV_DOWNLOAD=1 — skip NEW_BIND install (Cosmovisor fetches S3)"
elif [ "${SKIP_MAKE_INSTALL:-0}" = "1" ]; then
  echo "A: SKIP_MAKE_INSTALL=1 (use PATH $NEW_BIND)"
  command -v "$NEW_BIND" >/dev/null || { echo "$NEW_BIND not on PATH"; exit 1; }
else
  echo "A: make install NEW_BIND=$NEW_BIND from current tree"
  ( cd "$NEW_RELEASE_PATH" && make install )
  command -v "$NEW_BIND" >/dev/null || { echo "$NEW_BIND not on PATH"; exit 1; }
fi
if command -v "${NEW_BIND:-}" >/dev/null; then
  echo "A: NEW_BIND=$NEW_BIND ($("$NEW_BIND" version 2>/dev/null | head -1))"
fi

rm -rf "$VAL1HOME"
mkdir -p "$CHAINDIR"
"$OLD_BIND" init "$CHAINID" --overwrite --home "$VAL1HOME" --chain-id morocco-1
mkdir -p "$VAL1HOME/test-keys"

echo "A: fetching morocco-1 genesis"
curl -fL "$GENESIS_URL" -o "$VAL1HOME/config/genesis.json"

if [ "$STATE_SYNC" = "1" ]; then
  configure_statesync
else
  echo "A: STATE_SYNC=0 — unpacking snapshot $SNAPSHOT_PATH"
  if [ ! -f "$SNAPSHOT_PATH" ]; then
    [ -n "$SNAPSHOT_URL" ] || { echo "no snapshot and no SNAPSHOT_URL"; exit 1; }
    curl -fL "$SNAPSHOT_URL" -o "$SNAPSHOT_PATH"
  fi
  case "$SNAPSHOT_PATH" in
    *.lz4) lz4 -c -d "$SNAPSHOT_PATH" | tar -x -C "$VAL1HOME" ;;
    *.xz)  tar -xJf "$SNAPSHOT_PATH" -C "$VAL1HOME" ;;
    *.tar.gz|*.tgz) tar -xzf "$SNAPSHOT_PATH" -C "$VAL1HOME" ;;
    *) tar -xf "$SNAPSHOT_PATH" -C "$VAL1HOME" ;;
  esac
fi

"$OLD_BIND" --home "$VAL1HOME" config keyring-backend test || true
"$OLD_BIND" --home "$VAL1HOME" config chain-id morocco-1 || true
"$OLD_BIND" --home "$VAL1HOME" config node "tcp://localhost:$VAL1_RPC_PORT" || true

set +o pipefail
yes | "$OLD_BIND" --home "$VAL1HOME" keys add validator1 --output json > "$VAL1HOME/test-keys/val.json" 2>&1
set -o pipefail
VAL1ADDR=$(jq -r '.address' "$VAL1HOME/test-keys/val.json")

isolate_p2p

if [ "$STATE_SYNC" = "1" ]; then
  echo "A: OLD_BIND statesync (short-lived, then isolate)"
  : > "$OLD_LOG"
  "$OLD_BIND" start --home "$VAL1HOME" \
    --rpc.laddr "tcp://127.0.0.1:${VAL1_RPC_PORT}" \
    ${WASMVM_SKIP:+--wasm.skip_wasmvm_version_check} >>"$OLD_LOG" 2>&1 &
  START_PID=$!
  wait_rpc
  echo "A: waiting until catching_up=false"
  for i in $(seq 1 300); do
    cu=$(catching_up || echo true)
    h=$(rpc_height || echo 0)
    echo "  sync try=$i height=$h catching_up=$cu"
    if [ "$cu" = "false" ]; then
      break
    fi
    sleep 4
  done
  if [ "$(catching_up)" != "false" ]; then
    echo "A: statesync did not finish; aborting"
    kill "$START_PID" 2>/dev/null || true
    exit 1
  fi
  echo "A: appstate ready — dropping peers/statesync"
  sed -i.bak "/^\[statesync\]/,/^\[/ s/^enable *=.*/enable = false/" "$VAL1HOME/config/config.toml"
  sed -i.bak "/^\[statesync\]/,/^\[/ s|^rpc_servers *=.*|rpc_servers = \"\"|" "$VAL1HOME/config/config.toml"
  isolate_p2p
  kill "$START_PID" 2>/dev/null || true
  wait "$START_PID" 2>/dev/null || true
  sleep 2
fi

echo "A: OLD_BIND in-place-testnet --trigger-testnet-upgrade $UPGRADE_VERSION (no v6 handler)"
: > "$OLD_LOG"
"$OLD_BIND" in-place-testnet "$CHAINID" "$VAL1ADDR" \
  --trigger-testnet-upgrade "$UPGRADE_VERSION" \
  --home "$VAL1HOME" --skip-confirmation \
  --rpc.laddr "tcp://127.0.0.1:${VAL1_RPC_PORT}" \
  ${WASMVM_SKIP:+--wasm.skip_wasmvm_version_check} >>"$OLD_LOG" 2>&1 &
OLD_PID=$!

wait_rpc
echo "A: old node up at height $(rpc_height) pid=$OLD_PID — waiting for UPGRADE NEEDED halt"

HALT_H=""
for i in $(seq 1 180); do
  if ! kill -0 "$OLD_PID" 2>/dev/null; then
    echo "A: OLD_BIND exited"
    break
  fi
  if grep -q "UPGRADE \"${UPGRADE_VERSION}\" NEEDED" "$OLD_LOG" 2>/dev/null; then
    echo "A: halt signal in old log"
    HALT_H=$(rpc_height || true)
    kill "$OLD_PID" 2>/dev/null || true
    wait "$OLD_PID" 2>/dev/null || true
    break
  fi
  echo "  pre-upgrade h=$(rpc_height || echo ?) try=$i"
  sleep 2
done
wait "$OLD_PID" 2>/dev/null || true
sleep 2

if [ ! -f "$VAL1HOME/data/upgrade-info.json" ]; then
  echo "A: missing $VAL1HOME/data/upgrade-info.json — old binary did not dump halt info"
  tail -40 "$OLD_LOG"
  exit 1
fi
echo "A: upgrade-info.json=$(cat "$VAL1HOME/data/upgrade-info.json")"
if ! grep -q "UPGRADE \"${UPGRADE_VERSION}\" NEEDED" "$OLD_LOG"; then
  echo "A: old log has no UPGRADE NEEDED (did we use the v6 binary by mistake?)"
  tail -40 "$OLD_LOG"
  exit 1
fi

# Fetch published Cosmovisor JSON (live bucket) into $1 from URL or existing file.
fetch_cv_json() {
  local dest="$1" src="$2"
  mkdir -p "$(dirname "$dest")"
  case "$src" in
    https://*|http://*) curl -fsSL "$src" -o "$dest" ;;
    *) cp "$src" "$dest" ;;
  esac
  jq -e '.binaries["linux/amd64"] and .binaries["linux/arm64"]' "$dest" >/dev/null \
    || { echo "A: bad Cosmovisor JSON $src"; cat "$dest"; exit 1; }
  if grep -q -- '-dev' "$dest"; then
    echo "A: refuse -dev URLs in $dest"; cat "$dest"; exit 1
  fi
}

# Download the linux tarball Cosmovisor would fetch (GOOS/GOARCH + sha256).
fetch_cv_tarball() {
  local name="$1" json="$2"
  local key url bare want got tmp dest
  case "$(uname -m)" in
    aarch64|arm64) key="linux/arm64" ;;
    x86_64|amd64) key="linux/amd64" ;;
    *) echo "A: unsupported arch $(uname -m)"; exit 1 ;;
  esac
  url="$(jq -r --arg k "$key" '.binaries[$k] // empty' "$json")"
  [ -n "$url" ] || { echo "A: no binary URL for $key in $json"; exit 1; }
  echo "$url" | grep -q -- '-dev' && { echo "A: refuse -dev URL $url"; exit 1; }
  want="$(echo "$url" | sed -n 's/.*checksum=sha256:\([0-9a-f]*\).*/\1/p')"
  bare="${url%%\?*}"
  tmp="$(mktemp -d)"
  echo "A: fetching $key $bare"
  curl -fL --retry 3 -o "$tmp/pkg.tar.gz" "$bare"
  if command -v sha256sum >/dev/null; then
    got="$(sha256sum "$tmp/pkg.tar.gz" | awk '{print $1}')"
  else
    got="$(shasum -a 256 "$tmp/pkg.tar.gz" | awk '{print $1}')"
  fi
  if [ -n "$want" ] && [ "$got" != "$want" ]; then
    echo "A: checksum mismatch $key got=$got want=$want"; exit 1
  fi
  tar -tzf "$tmp/pkg.tar.gz" | grep -Eqx '\.?/?terpd' \
    || { echo "A: tarball has no root terpd"; tar -tzf "$tmp/pkg.tar.gz" | head; exit 1; }
  dest="$VAL1HOME/cosmovisor/upgrades/${name}/bin"
  mkdir -p "$dest"
  tar -xzf "$tmp/pkg.tar.gz" -C "$tmp"
  if [ -f "$tmp/terpd" ]; then
    cp "$tmp/terpd" "$dest/terpd"
  elif [ -f "$tmp/./terpd" ]; then
    cp "$tmp/./terpd" "$dest/terpd"
  else
    echo "A: extract missed terpd"; ls -la "$tmp"; exit 1
  fi
  chmod +x "$dest/terpd"
  rm -rf "$tmp"
  echo "A: installed $dest/terpd from S3 ($key sha256=$got)"
}

# in-place-testnet dumps upgrade-info without plan.info. Stamp published
# binaries JSON so Cosmovisor can download (same as e.sh gov plan.info).
stamp_upgrade_info() {
  local name="$1" json="$2"
  local file="$VAL1HOME/data/upgrade-info.json"
  [ -f "$file" ] || return 1
  [ -f "$json" ] || return 1
  local n compact tmp
  n="$(jq -r '.name // empty' "$file")"
  [ "$n" = "$name" ] || return 0
  compact="$(jq -c . "$json")"
  tmp="$(mktemp)"
  jq --arg info "$compact" '.info = $info' "$file" > "$tmp"
  mv "$tmp" "$file"
  echo "A: stamped upgrade-info.json name=$name info from $json"
}

setup_cosmovisor_upgrades() {
  local cv="${CV_BIND:-cosmovisor}"
  command -v "$cv" >/dev/null || { echo "A: USE_COSMOVISOR=1 but $cv not on PATH"; exit 1; }
  mkdir -p "$VAL1HOME/cosmovisor/genesis/bin"
  cp "$(command -v "$OLD_BIND")" "$VAL1HOME/cosmovisor/genesis/bin/terpd"
  chmod +x "$VAL1HOME/cosmovisor/genesis/bin/terpd"
  export DAEMON_NAME=terpd
  export DAEMON_HOME="$VAL1HOME"
  export DAEMON_RESTART_AFTER_UPGRADE=true
  export DAEMON_POLL_INTERVAL=300ms
  export DAEMON_SHUTDOWN_GRACE=15s
  export UNSAFE_SKIP_BACKUP=true

  if [ "${CV_DOWNLOAD:-0}" = "1" ]; then
    rm -rf "$VAL1HOME/cosmovisor/upgrades/${UPGRADE_VERSION}" \
      "$VAL1HOME/cosmovisor/upgrades/v6.2" \
      "$VAL1HOME/cosmovisor/current"
    fetch_cv_json "$VAL1HOME/cv-v61.json" \
      "${CV_JSON_V61:-https://s3.terp.network/upgrades/v6.1/cosmovisor.json}"
    stamp_upgrade_info "$UPGRADE_VERSION" "$VAL1HOME/cv-v61.json"
    # Halt already wrote v6.1 upgrade-info, so Cosmovisor will not download
    # that plan at start. Install v6.1 from S3 (or NEW_BIND if testing a
    # recut handler). Do not pre-place v6.2 and do not stamp v6.2 info —
    # the v6.1 binary writes plan.info as the published JSON URL.
    if command -v "${NEW_BIND:-}" >/dev/null && [ "${CV_V61_FROM_PATH:-0}" = "1" ]; then
      mkdir -p "$VAL1HOME/cosmovisor/upgrades/${UPGRADE_VERSION}/bin"
      cp "$(command -v "$NEW_BIND")" "$VAL1HOME/cosmovisor/upgrades/${UPGRADE_VERSION}/bin/terpd"
      chmod +x "$VAL1HOME/cosmovisor/upgrades/${UPGRADE_VERSION}/bin/terpd"
      echo "A: CV_V61_FROM_PATH=1 upgrades/${UPGRADE_VERSION}=$NEW_BIND (handler writes v6.2 URL)"
    else
      fetch_cv_tarball "$UPGRADE_VERSION" "$VAL1HOME/cv-v61.json"
    fi
    ln -sfn "$VAL1HOME/cosmovisor/upgrades/${UPGRADE_VERSION}" "$VAL1HOME/cosmovisor/current"
    echo "A: CV_DOWNLOAD=1 v6.2 via Cosmovisor GET of plan.info URL (no operator stamp)"
    echo "A: upgrade-info=$(cat "$VAL1HOME/data/upgrade-info.json")"
    export DAEMON_ALLOW_DOWNLOAD_BINARIES=true
    # Pointer URL has no ?checksum= (v6.2 hashes are inside the JSON). Default
    # Cosmovisor is false; tarball URLs in the JSON still carry sha256.
    export DAEMON_DOWNLOAD_MUST_HAVE_CHECKSUM=false
  else
    mkdir -p "$VAL1HOME/cosmovisor/upgrades/${UPGRADE_VERSION}/bin"
    cp "$(command -v "$NEW_BIND")" "$VAL1HOME/cosmovisor/upgrades/${UPGRADE_VERSION}/bin/terpd"
    chmod +x "$VAL1HOME/cosmovisor/upgrades/${UPGRADE_VERSION}/bin/terpd"
    if command -v "${V62_BIND:-terpd-v62}" >/dev/null; then
      mkdir -p "$VAL1HOME/cosmovisor/upgrades/v6.2/bin"
      cp "$(command -v "${V62_BIND:-terpd-v62}")" "$VAL1HOME/cosmovisor/upgrades/v6.2/bin/terpd"
      chmod +x "$VAL1HOME/cosmovisor/upgrades/v6.2/bin/terpd"
      echo "A: Cosmovisor pre-place genesis=$OLD_BIND upgrades/${UPGRADE_VERSION}=$NEW_BIND upgrades/v6.2=${V62_BIND:-terpd-v62}"
    else
      echo "A: Cosmovisor pre-place genesis=$OLD_BIND upgrades/${UPGRADE_VERSION}=$NEW_BIND (no v6.2 bin)"
    fi
    ln -sfn "$VAL1HOME/cosmovisor/upgrades/${UPGRADE_VERSION}" "$VAL1HOME/cosmovisor/current"
    export DAEMON_ALLOW_DOWNLOAD_BINARIES=false
  fi
}

echo "A: NEW_BIND start (v6 handler) on same home"
: > "$NEW_LOG"
if [ "${USE_COSMOVISOR:-0}" = "1" ]; then
  setup_cosmovisor_upgrades
  "${CV_BIND:-cosmovisor}" run start --home "$VAL1HOME" \
    --rpc.laddr "tcp://127.0.0.1:${VAL1_RPC_PORT}" \
    ${WASMVM_SKIP:+--wasm.skip_wasmvm_version_check} >>"$NEW_LOG" 2>&1 &
else
  "$NEW_BIND" start --home "$VAL1HOME" \
    --rpc.laddr "tcp://127.0.0.1:${VAL1_RPC_PORT}" \
    ${WASMVM_SKIP:+--wasm.skip_wasmvm_version_check} >>"$NEW_LOG" 2>&1 &
fi
NEW_PID=$!

wait_rpc
echo "A: new node up at height $(rpc_height) pid=$NEW_PID"

APPLIED_H=""
for i in $(seq 1 120); do
  APPLIED_H=$(applied_height || true)
  h=$(rpc_height || echo 0)
  echo "  post-upgrade h=$h applied_height=${APPLIED_H:-none} try=$i"
  if [ -n "$APPLIED_H" ] && [ "$APPLIED_H" != "0" ]; then
    break
  fi
  if ! kill -0 "$NEW_PID" 2>/dev/null; then
    echo "A: NEW_BIND died"
    tail -50 "$NEW_LOG"
    exit 1
  fi
  sleep 2
done
if [ -z "$APPLIED_H" ] || [ "$APPLIED_H" = "0" ]; then
  echo "A: $UPGRADE_VERSION not applied"
  tail -50 "$NEW_LOG"
  exit 1
fi

AFTER=$(rpc_height)
TARGET=$((AFTER + POST_BLOCKS))
echo "A: waiting for $POST_BLOCKS good blocks after apply (from $AFTER to >= $TARGET)"
for i in $(seq 1 120); do
  h=$(rpc_height || echo 0)
  echo "  post-apply h=$h target=$TARGET try=$i"
  if [ "$h" -ge "$TARGET" ]; then
    break
  fi
  if ! kill -0 "$NEW_PID" 2>/dev/null; then
    echo "A: NEW_BIND died while producing post-upgrade blocks"
    tail -50 "$NEW_LOG"
    exit 1
  fi
  sleep 2
done
h=$(rpc_height)
if [ "$h" -lt "$TARGET" ]; then
  echo "A: did not produce post-upgrade blocks (h=$h target=$TARGET)"
  tail -50 "$NEW_LOG"
  exit 1
fi

"$(query_bin)" q wasm params --home "$VAL1HOME" -o json | jq '.circuit_upload_access.permission // .'
"$(query_bin)" q tokenfactory params --home "$VAL1HOME" -o json | jq '.params // .'
"$(query_bin)" q ibc client states --home "$VAL1HOME" -o json | jq '.client_states | length'
echo "A: upgrade workflow finished applied=$UPGRADE_VERSION at $APPLIED_H height=$h (halt info was $(cat "$VAL1HOME/data/upgrade-info.json"))"
