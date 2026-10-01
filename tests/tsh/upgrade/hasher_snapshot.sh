#!/usr/bin/env bash
# Unpack a morocco-1 pruned pack (data/ + wasm/) + genesis into HOME_DIR.
# Does not start the node. Writes validator acc address to $HOME_DIR/test-keys/val.addr
set -euo pipefail

HOME_DIR="${HOME_DIR:?}"
BIND="${BIND:?}"
GENESIS_URL="${GENESIS_URL:-https://raw.githubusercontent.com/terpnetwork/networks/main/mainnet/morocco-1/genesis.json}"
SNAPSHOT_INDEX="${SNAPSHOT_INDEX:-https://minio.terp.network/snapshots/mainnet/morocco-1/pruned/snapshot.json}"
SNAPSHOT_PATH="${SNAPSHOT_PATH:-}"
SNAPSHOT_URL="${SNAPSHOT_URL:-}"
CHAIN_ID_INIT="${CHAIN_ID_INIT:-morocco-1}"
KEYRING="${KEYRING:-test}"
KEYALGO="${KEYALGO:-secp256k1}"
RPC="${RPC:-26657}"
P2P="${P2P:-26656}"
GRPC="${GRPC:-9090}"
REST="${REST:-1317}"
TIMEOUT_COMMIT="${TIMEOUT_COMMIT:-1s}"

if [ -z "$SNAPSHOT_PATH" ] && [ -z "$SNAPSHOT_URL" ]; then
  SNAPSHOT_URL="$(curl -sfL "$SNAPSHOT_INDEX" | jq -r '.latest // .url // .snapshots[0] // empty')"
  [ -n "$SNAPSHOT_URL" ] && [ "$SNAPSHOT_URL" != "null" ] || {
    echo "hasher_snapshot: could not resolve latest from $SNAPSHOT_INDEX"
    exit 1
  }
fi
if echo "${SNAPSHOT_URL:-$SNAPSHOT_PATH}" | grep -qE '22807932|22749033'; then
  echo "hasher_snapshot: refusing pre-v6 pack ${SNAPSHOT_URL:-$SNAPSHOT_PATH}"
  exit 1
fi
if [ -z "$SNAPSHOT_PATH" ]; then
  SNAPSHOT_PATH="${SNAPSHOT_CACHE:-/tmp/terp-morocco-1-pruned.tar.lz4}"
fi
if [ ! -f "$SNAPSHOT_PATH" ]; then
  [ -n "${SNAPSHOT_URL:-}" ] || { echo "hasher_snapshot: no SNAPSHOT_PATH/URL"; exit 1; }
  echo "hasher_snapshot: downloading $SNAPSHOT_URL -> $SNAPSHOT_PATH"
  curl -fL --retry 3 -o "$SNAPSHOT_PATH" "$SNAPSHOT_URL"
fi

rm -rf "$HOME_DIR"
mkdir -p "$HOME_DIR/test-keys" "$HOME_DIR/config"
"$BIND" init localterp --home "$HOME_DIR" --chain-id "$CHAIN_ID_INIT" --overwrite --default-denom uterp >/dev/null

if [ -f "${GENESIS_FILE:-}" ]; then
  cp "$GENESIS_FILE" "$HOME_DIR/config/genesis.json"
else
  echo "hasher_snapshot: fetching genesis $GENESIS_URL"
  curl -fL --retry 3 -o "$HOME_DIR/config/genesis.json" "$GENESIS_URL"
fi

echo "hasher_snapshot: unpacking $SNAPSHOT_PATH"
case "$SNAPSHOT_PATH" in
  *.lz4) lz4 -c -d "$SNAPSHOT_PATH" | tar -x -C "$HOME_DIR" ;;
  *.xz) tar -xJf "$SNAPSHOT_PATH" -C "$HOME_DIR" ;;
  *.tar.gz|*.tgz) tar -xzf "$SNAPSHOT_PATH" -C "$HOME_DIR" ;;
  *) tar -xf "$SNAPSHOT_PATH" -C "$HOME_DIR" ;;
esac
[ -d "$HOME_DIR/data" ] || { echo "hasher_snapshot: pack had no data/"; exit 1; }

cfg="$HOME_DIR/config/config.toml"
sed -i.bak "/^\[rpc\]/,/^\[/ s/^laddr *=.*/laddr = \"tcp:\/\/127.0.0.1:${RPC}\"/" "$cfg"
sed -i.bak "/^\[rpc\]/,/^\[/ s/^pprof_laddr *=.*/pprof_laddr = \"localhost:16060\"/" "$cfg"
sed -i.bak "/^\[p2p\]/,/^\[/ s/^laddr *=.*/laddr = \"tcp:\/\/127.0.0.1:${P2P}\"/" "$cfg"
sed -i.bak "/^\[p2p\]/,/^\[/ s/^pex *=.*/pex = false/" "$cfg"
sed -i.bak "/^\[p2p\]/,/^\[/ s/^seeds *=.*/seeds = \"\"/" "$cfg"
sed -i.bak "/^\[p2p\]/,/^\[/ s/^persistent_peers *=.*/persistent_peers = \"\"/" "$cfg"
sed -i.bak "/^\[consensus\]/,/^\[/ s/^[[:space:]]*timeout_commit[[:space:]]*=.*/timeout_commit = \"${TIMEOUT_COMMIT}\"/" "$cfg"
sed -i.bak "/^\[api\]/,/^\[/ s/address.*/address = \"tcp:\/\/127.0.0.1:${REST}\"/" "$HOME_DIR/config/app.toml" || true
sed -i.bak "/^\[grpc\]/,/^\[/ s/address.*/address = \"localhost:${GRPC}\"/" "$HOME_DIR/config/app.toml" || true

"$BIND" --home "$HOME_DIR" config keyring-backend "$KEYRING" || true
"$BIND" --home "$HOME_DIR" config chain-id test-1 || true
"$BIND" --home "$HOME_DIR" config node "tcp://127.0.0.1:${RPC}" || true

set +o pipefail
yes | "$BIND" --home "$HOME_DIR" keys add validator1 --keyring-backend "$KEYRING" --algo "$KEYALGO" --output json \
  > "$HOME_DIR/test-keys/val.json" 2>/dev/null
set -o pipefail
VAL1ADDR="$(jq -r '.address' "$HOME_DIR/test-keys/val.json")"
[ -n "$VAL1ADDR" ] && [ "$VAL1ADDR" != "null" ] || { echo "hasher_snapshot: no validator address"; cat "$HOME_DIR/test-keys/val.json"; exit 1; }
printf '%s\n' "$VAL1ADDR" > "$HOME_DIR/test-keys/val.addr"

echo "decorate bright ozone fork gallery riot bus exhaust worth way bone indoor calm squirrel merry zero scheme cotton until shop any excess stage laundry" | \
  "$BIND" keys add terp1 --home "$HOME_DIR" --keyring-backend "$KEYRING" --algo "$KEYALGO" --recover >/dev/null || true
echo "wealth flavor believe regret funny network recall kiss grape useless pepper cram hint member few certain unveil rather brick bargain curious require crowd raise" | \
  "$BIND" keys add terp2 --home "$HOME_DIR" --keyring-backend "$KEYRING" --algo "$KEYALGO" --recover >/dev/null || true

echo "hasher_snapshot: ready home=$HOME_DIR val=$VAL1ADDR pack=$SNAPSHOT_PATH"
