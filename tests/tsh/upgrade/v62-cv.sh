#!/usr/bin/env bash
####################################################################
# TSH: morocco-1 v6 snapshot → Cosmovisor v6.1 then v6.2 (Upgrade A then B)
#
# OLD_BIND=terpd-v6 (never 5.2.0). Snapshot is data/+wasm/ only; genesis
# separate. Pin: morocco-1_22911849_2026-09-02T03-49-50Z.tar.lz4
# Do not use pruned 22807932 or archive 22749033 (pre-v6).
#
# x/upgrade stores ONE plan. A tx may list both MsgSoftwareUpgrade
# messages (v6.1 at H, v6.2 at H+2); the last ScheduleUpgrade wins, so
# the v6.1 handler re-arms v6.2 at BlockHeight()+2.
#
# Cosmovisor:
#   genesis/bin/terpd              = terpd-v6
#   upgrades/v6.1/bin/terpd        = V61_BIND (feat/6.1.0-dev, no v6.2 handler)
#   upgrades/v6.2/bin/terpd        = V62_BIND (this tree)
#   DAEMON_ALLOW_DOWNLOAD_BINARIES = false (pre-place). Tarballs from
#   make release-prep PLAN=v6.2 are the download-shaped pack (member terpd).
#
#   STATE_SYNC=0 SKIP_INSTALL=1 V61_BIND=terpd-v61 \
#     SNAPSHOT_URL='https://minio.terp.network/snapshots/mainnet/morocco-1/pruned/morocco-1_22911849_2026-09-02T03-49-50Z.tar.lz4' \
#     bash tests/tsh/upgrade/v62-cv.sh
####################################################################
set -euo pipefail
export PATH="/usr/local/go/bin:/usr/local/bin:/opt/homebrew/bin:${HOME}/go/bin:${PATH}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../../.." && pwd)"
export UPGRADE_VERSION="${UPGRADE_VERSION:-v6.1}"
export STATE_SYNC="${STATE_SYNC:-0}"
export OLD_BIND="${OLD_BIND:-terpd-v6}"
export V61_BIND="${V61_BIND:-terpd-v61}"
export V62_BIND="${V62_BIND:-terpd}"
export NEW_BIND="${NEW_BIND:-$V62_BIND}"
export CHAINID="${CHAINID:-test-1}"
export NEW_RELEASE_PATH="${NEW_RELEASE_PATH:-$REPO}"
export GENESIS_URL="${GENESIS_URL:-https://raw.githubusercontent.com/terpnetwork/networks/main/mainnet/morocco-1/genesis.json}"
export SNAPSHOT_INDEX="${SNAPSHOT_INDEX:-https://minio.terp.network/snapshots/mainnet/morocco-1/pruned/snapshot.json}"
export SNAPSHOT_URL="${SNAPSHOT_URL:-https://minio.terp.network/snapshots/mainnet/morocco-1/pruned/morocco-1_22911849_2026-09-02T03-49-50Z.tar.lz4}"
export OLD_LOG="${OLD_LOG:-/tmp/tsh-v62-old.log}"
export NEW_LOG="${NEW_LOG:-/tmp/tsh-v62-cv.log}"
export POST_BLOCKS="${POST_BLOCKS:-3}"
export SKIP_NEW_START=1
export SKIP_INSTALL="${SKIP_INSTALL:-1}"
CV_BIND="${CV_BIND:-cosmovisor}"
PLAN_A="${PLAN_A:-v6.1}"
PLAN_B="${PLAN_B:-v6.2}"
HALT_GAP="${HALT_GAP:-2}"

if ! command -v "$OLD_BIND" >/dev/null; then
  echo "OLD_BIND=$OLD_BIND not on PATH (install v6 as terpd-v6). Do not use 5.2.0."
  exit 1
fi
_oldver="$("$OLD_BIND" version 2>/dev/null | head -1 || true)"
if echo "$_oldver" | grep -qE '^5\.'; then
  echo "OLD_BIND=$OLD_BIND is $_oldver — must start from the v6 binary"
  exit 1
fi
command -v "$V61_BIND" >/dev/null || { echo "V61_BIND=$V61_BIND not on PATH (feat/6.1.0-dev)"; exit 1; }
command -v "$V62_BIND" >/dev/null || { echo "V62_BIND=$V62_BIND not on PATH (this feat/6.2.0-dev tree)"; exit 1; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }

if echo "$SNAPSHOT_URL" | grep -qE '22807932|22749033'; then
  echo "refusing pre-v6 snapshot $SNAPSHOT_URL"
  exit 1
fi

if [ -z "${SNAPSHOT_PATH:-}" ] && [ "$STATE_SYNC" = "0" ]; then
  export SNAPSHOT_PATH="${SNAPSHOT_PATH:-/tmp/terp-morocco-1-pruned.tar.lz4}"
fi

echo "v62-cv: OLD=$OLD_BIND V61=$V61_BIND V62=$V62_BIND snapshot=${SNAPSHOT_URL:-$SNAPSHOT_PATH}"

# Snapshot + in-place-testnet halt on v6.1 (v6 binary has no v6.1 handler).
# shellcheck disable=SC1091
source "$ROOT/a.sh"

: "${VAL1HOME:?}" "${VAL1_RPC_PORT:?}"
VAL1HOME="$(cd "$VAL1HOME" && pwd)"
HOME_DIR="$VAL1HOME"

stop_cv() {
  local pid
  pid="${CV_PID:-}"
  if [ -z "${pid:-}" ] && [ -f "$HOME_DIR/cosmovisor.pid" ]; then
    pid="$(cat "$HOME_DIR/cosmovisor.pid" 2>/dev/null || true)"
  fi
  if [ -n "${pid:-}" ]; then
    echo "v62-cv: stopping cosmovisor pid=$pid"
    kill "$pid" 2>/dev/null || true
    sleep 2
    kill -9 "$pid" 2>/dev/null || true
    pkill -P "$pid" 2>/dev/null || true
  fi
  if [ -n "${OLD_PID:-}" ]; then
    kill "$OLD_PID" 2>/dev/null || true
    kill -9 "$OLD_PID" 2>/dev/null || true
  fi
  rm -f "$HOME_DIR/cosmovisor.pid"
}
trap stop_cv EXIT
info="$HOME_DIR/data/upgrade-info.json"
H1="$(jq -r '.height // empty' "$info" 2>/dev/null || true)"
if [ -z "$H1" ] || [ "$H1" = "null" ]; then
  H1="$(jq -r '.Height // empty' "$info" 2>/dev/null || true)"
fi
# upgrade-info.json is {"name":"v6.1","height":N} or nested.
if [ -z "$H1" ] || [ "$H1" = "null" ]; then
  H1="$(python3 -c "import json; d=json.load(open('$info')); print(d.get('height') or d.get('Height') or (d.get('plan') or {}).get('height') or '')")"
fi
[ -n "$H1" ] || { echo "could not parse halt height from $info: $(cat "$info")"; exit 1; }
H2=$((H1 + HALT_GAP))
echo "v62-cv: plan $PLAN_A height=$H1 ; $PLAN_B height=$H2 (gap=$HALT_GAP)"

# Dual-message proposal artifact (same tx). Last ScheduleUpgrade wins in
# x/upgrade; v6.1 handler re-arms v6.2 at +2 so B still runs.
mkdir -p "$HOME_DIR"
jq -n \
  --arg h1 "$H1" --arg h2 "$H2" \
  --arg a "$PLAN_A" --arg b "$PLAN_B" \
  '{
    messages: [
      {
        "@type": "/cosmos.upgrade.v1beta1.MsgSoftwareUpgrade",
        authority: "terp10d07y265gmmuvt4z0w9aw880jnsr700jag6fuq",
        plan: { name: $a, time: "0001-01-01T00:00:00Z", height: $h1, info: "", upgraded_client_state: null }
      },
      {
        "@type": "/cosmos.upgrade.v1beta1.MsgSoftwareUpgrade",
        authority: "terp10d07y265gmmuvt4z0w9aw880jnsr700jag6fuq",
        plan: { name: $b, time: "0001-01-01T00:00:00Z", height: $h2, info: "", upgraded_client_state: null }
      }
    ],
    metadata: "",
    deposit: "50000000uterp",
    title: "v6.1 then v6.2 (Upgrade A then B)",
    summary: "Two MsgSoftwareUpgrade in one proposal. x/upgrade keeps one plan (last wins). v6.1 handler re-arms v6.2 at height+2. Cosmovisor pre-places both plan dirs.",
    expedited: true
  }' > "$HOME_DIR/dual-v61-v62.json"
cp "$HOME_DIR/dual-v61-v62.json" "$REPO/networks/upgrades/v6.2/dual_proposal.json"
echo "v62-cv: wrote dual proposal $HOME_DIR/dual-v61-v62.json"

if ! command -v "$CV_BIND" >/dev/null; then
  echo "v62-cv: installing cosmovisor v1.7.1"
  GOTOOLCHAIN=auto go install cosmossdk.io/tools/cosmovisor/cmd/cosmovisor@v1.7.1
fi
command -v "$CV_BIND" >/dev/null || { echo "cosmovisor missing"; exit 1; }

old_bin="$(command -v "$OLD_BIND")"
v61_bin="$(command -v "$V61_BIND")"
v62_bin="$(command -v "$V62_BIND")"
mkdir -p "$HOME_DIR/cosmovisor/genesis/bin" \
  "$HOME_DIR/cosmovisor/upgrades/${PLAN_A}/bin" \
  "$HOME_DIR/cosmovisor/upgrades/${PLAN_B}/bin"
cp "$old_bin" "$HOME_DIR/cosmovisor/genesis/bin/terpd"
cp "$v61_bin" "$HOME_DIR/cosmovisor/upgrades/${PLAN_A}/bin/terpd"
cp "$v62_bin" "$HOME_DIR/cosmovisor/upgrades/${PLAN_B}/bin/terpd"
chmod +x "$HOME_DIR/cosmovisor/genesis/bin/terpd" \
  "$HOME_DIR/cosmovisor/upgrades/${PLAN_A}/bin/terpd" \
  "$HOME_DIR/cosmovisor/upgrades/${PLAN_B}/bin/terpd"
# Cosmovisor current still points at genesis until first swap.
ln -sfn "$HOME_DIR/cosmovisor/upgrades/${PLAN_A}" "$HOME_DIR/cosmovisor/current"
echo "v62-cv: CV genesis=$old_bin $PLAN_A=$v61_bin $PLAN_B=$v62_bin"

export DAEMON_NAME=terpd
export DAEMON_HOME="$HOME_DIR"
export DAEMON_RESTART_AFTER_UPGRADE=true
export DAEMON_POLL_INTERVAL=300ms
export UNSAFE_SKIP_BACKUP=true
export DAEMON_ALLOW_DOWNLOAD_BINARIES=false
export DAEMON_DATA_BACKUP_DIR="$HOME_DIR/data-backup"
mkdir -p "$DAEMON_DATA_BACKUP_DIR"

: > "$NEW_LOG"
echo "v62-cv: cosmovisor run start --home $HOME_DIR (pruning=everything after B is verified live)"
nohup "$CV_BIND" run start --home "$HOME_DIR" --pruning=everything --minimum-gas-prices=0uterp \
  --rpc.laddr="tcp://0.0.0.0:${VAL1_RPC_PORT}" --log_level info \
  ${WASMVM_SKIP:+--wasm.skip_wasmvm_version_check} >>"$NEW_LOG" 2>&1 &
echo $! > "$HOME_DIR/cosmovisor.pid"
CV_PID=$(cat "$HOME_DIR/cosmovisor.pid")

wait_rpc
echo "v62-cv: RPC up height=$(rpc_height) current=$(readlink "$HOME_DIR/cosmovisor/current")"

applied_a() {
  "$HOME_DIR/cosmovisor/upgrades/${PLAN_A}/bin/terpd" q upgrade applied "$PLAN_A" \
    --home "$HOME_DIR" --node "tcp://127.0.0.1:${VAL1_RPC_PORT}" -o json 2>/dev/null \
    | jq -r '.height // empty' || true
}
applied_b() {
  "$HOME_DIR/cosmovisor/upgrades/${PLAN_B}/bin/terpd" q upgrade applied "$PLAN_B" \
    --home "$HOME_DIR" --node "tcp://127.0.0.1:${VAL1_RPC_PORT}" -o json 2>/dev/null \
    | jq -r '.height // empty' || true
}

ok=0
for i in $(seq 1 180); do
  if grep -q "UPGRADE \"${PLAN_B}\" NEEDED" "$NEW_LOG" 2>/dev/null; then
    echo "v62-cv: saw $PLAN_B NEEDED — genesis/v6.1 panics without exit; point current at $PLAN_B"
    if [ -n "${CV_PID:-}" ]; then
      kill "$CV_PID" 2>/dev/null || true
      sleep 2
      kill -9 "$CV_PID" 2>/dev/null || true
    fi
    ln -sfn "$HOME_DIR/cosmovisor/upgrades/${PLAN_B}" "$HOME_DIR/cosmovisor/current"
    nohup "$CV_BIND" run start --home "$HOME_DIR" --pruning=everything --minimum-gas-prices=0uterp \
      --rpc.laddr="tcp://0.0.0.0:${VAL1_RPC_PORT}" --log_level info \
      ${WASMVM_SKIP:+--wasm.skip_wasmvm_version_check} >>"$NEW_LOG" 2>&1 &
    echo $! > "$HOME_DIR/cosmovisor.pid"
    CV_PID=$(cat "$HOME_DIR/cosmovisor.pid")
    break
  fi
  ah=$(applied_a)
  bh=$(applied_b)
  echo "  wait A/B applied a=${ah:-none} b=${bh:-none} h=$(rpc_height || echo ?) try=$i"
  if [ -n "${bh:-}" ] && [ "$bh" != "0" ]; then
    ok=1
    break
  fi
  sleep 2
done

wait_rpc
ok=0
for i in $(seq 1 60); do
  ah=$(applied_a)
  bh=$(applied_b)
  h=$(rpc_height || echo 0)
  echo "  post h=$h applied $PLAN_A=${ah:-none} $PLAN_B=${bh:-none} current=$(readlink "$HOME_DIR/cosmovisor/current") try=$i"
  if [ -n "${ah:-}" ] && [ "$ah" != "0" ] && [ -n "${bh:-}" ] && [ "$bh" != "0" ]; then
    ok=1
    break
  fi
  sleep 2
done
[ "$ok" = "1" ] || { echo "v62-cv: dual upgrade did not apply"; tail -80 "$NEW_LOG"; exit 1; }

ah=$(applied_a)
bh=$(applied_b)
gap=$((bh - ah))
if [ "$gap" -ne "$HALT_GAP" ]; then
  echo "v62-cv: expected $PLAN_B = $PLAN_A + $HALT_GAP (got $bh - $ah = $gap)"
  exit 1
fi
echo "v62-cv: applied $PLAN_A at $ah $PLAN_B at $bh (gap=$gap)"

if ! grep -q "v6.1: curated store\|v6.1: armed plan v6.2" "$NEW_LOG"; then
  echo "v62-cv: missing v6.1 copy/arm logs"
  tail -80 "$NEW_LOG"
  exit 1
fi
if grep -q "refusing to rehash IBC-facing store" "$NEW_LOG"; then
  echo "v62-cv: IBC rehash refused — fail closed"
  exit 1
fi
if ! grep -q "v6.2: dropping unmounted b3-" "$NEW_LOG"; then
  echo "v62-cv: missing v6.2 drop-dest log"
  tail -80 "$NEW_LOG"
  exit 1
fi
if grep -q "v6.2: mounted store keys" "$NEW_LOG" && grep "v6.2: mounted store keys" "$NEW_LOG" | grep -q "b3-bank"; then
  echo "v62-cv: b3-bank still mounted after B"
  grep "v6.2: mounted store keys" "$NEW_LOG"
  exit 1
fi
if grep -q "v6.2: mounted store keys" "$NEW_LOG" && grep "v6.2: mounted store keys" "$NEW_LOG" | grep -qE "b3-"; then
  echo "v62-cv: b3-* dest still mounted after B"
  grep "v6.2: mounted store keys" "$NEW_LOG"
  exit 1
fi

AFTER=$(rpc_height)
TARGET=$((AFTER + POST_BLOCKS))
for i in $(seq 1 60); do
  h=$(rpc_height || echo 0)
  echo "  post-B produce h=$h target=$TARGET try=$i"
  [ "$h" -ge "$TARGET" ] && break
  sleep 2
done
h=$(rpc_height)
[ "$h" -ge "$TARGET" ] || { echo "v62-cv: did not produce post-B blocks"; exit 1; }

"$v62_bin" q bank total --home "$HOME_DIR" --node "tcp://127.0.0.1:${VAL1_RPC_PORT}" -o json >/dev/null
"$v62_bin" q upgrade applied "$PLAN_A" --home "$HOME_DIR" --node "tcp://127.0.0.1:${VAL1_RPC_PORT}" -o json
"$v62_bin" q upgrade applied "$PLAN_B" --home "$HOME_DIR" --node "tcp://127.0.0.1:${VAL1_RPC_PORT}" -o json
echo "v62-cv: pruning=everything still serving bank after suffix removal"

export NEW_BIND="$V62_BIND"
export VAL1HOME
# shellcheck disable=SC1091
source "$ROOT/query-all-params.sh"

echo "v62-cv OK dual Cosmovisor $PLAN_A@$ah → $PLAN_B@$bh"
