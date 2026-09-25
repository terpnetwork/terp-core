#!/usr/bin/env bash
# Morocco-1 snapshot epoch on groot2 — LOCAL HUB ONLY.
#
# Public sentries (Akash rpc.terp.network) statesync from host-rpc. This job
# must never remanifest, SSH, or wipe those pods. It only:
#   1) Spawn an ephemeral terpd on this machine, statesync from LIVE_RPC (LAN hub).
#   2) Tar data/+wasm/ and publish to usb2 snapshots/ (not static/terp.network).
# Archive halt-copy (stop_live) is opt-in: OLINE_DANGER_HALT_LIVE=1.
#
# Never copies config/, node_key, priv_validator_key, addrbook, or keyring.
# Never oline manage update/restart of Akash dseqs.
set -euo pipefail

LIVE_HOME="${LIVE_HOME:-/home/returniflost/.terpd-mainnet}"
LIVE_BIN="${LIVE_BIN:-/home/returniflost/go/bin/terpd-mainnet}"
# Cosmovisor DAEMON_NAME (binary filename under current/bin/). Live systemd
# may still ExecStart the raw daemon; we never start a second Cosmovisor.
DAEMON_NAME="${DAEMON_NAME:-terpd-mainnet}"
LIVE_UNIT="${LIVE_UNIT:-terpd-mainet.service}"
LIVE_RPC="${LIVE_RPC:-http://192.168.10.101:26657}"
LIVE_P2P="${LIVE_P2P:-192.168.10.101:26656}"
LIVE_NODE_ID="${LIVE_NODE_ID:-2fe71f763da2e549cd4e8386afeadea39bcd8f4c}"

EPOCH_ROOT="${EPOCH_ROOT:-/storage/chain/snapshot-epoch}"
EPH_HOME="${EPH_HOME:-$EPOCH_ROOT/pruned-home}"
EPH_RPC_PORT="${EPH_RPC_PORT:-27657}"
EPH_P2P_PORT="${EPH_P2P_PORT:-27656}"
EPH_RPC="http://127.0.0.1:${EPH_RPC_PORT}"

CHAIN_ID="${CHAIN_ID:-morocco-1}"
NETWORK="${NETWORK:-mainnet}"
MC_ALIAS="${MC_ALIAS:-usb2}"
S3_BUCKET="${S3_BUCKET:-snapshots}"
PUBLIC_BASE="${PUBLIC_BASE:-https://minio.terp.network}"
KEEP_LAST="${KEEP_LAST:-1}"
# pruned | archive | both | resolve-only | reap-only
# resolve-only: copy live Cosmovisor/current (or running exe) and exit (no spawn)
# reap-only: kill leftover --home $EPH_HOME processes and exit (no spawn, no upload)
CLASS="${CLASS:-pruned}"
TRUST_LAG="${TRUST_LAG:-2000}"
SYNC_TIMEOUT_SEC="${SYNC_TIMEOUT_SEC:-10800}"
DRY_RUN="${DRY_RUN:-0}"
LOCK_FILE="${LOCK_FILE:-$EPOCH_ROOT/curate.lock}"
# Plan v6 halt. Packs below this are 5.2.0 state (cw-hooks store version 0).
V6_HALT_HEIGHT="${V6_HALT_HEIGHT:-22810000}"

PREFIX="${S3_BUCKET}/${NETWORK}/${CHAIN_ID}"
STOPPED_LIVE=0
EPH_PID=""
EPH_BIN=""
QUERY_BIN=""
BIN_SOURCE=""


assert_local_hub() {
  case "$LIVE_RPC" in
    http://127.0.0.1:*|http://192.168.10.101:*|http://192.168.10.102:*) ;;
    *) die "LOCAL ONLY: LIVE_RPC=$LIVE_RPC is not the house hub — refusing" ;;
  esac
  case "$LIVE_P2P" in
    127.0.0.1:*|192.168.10.101:*|192.168.10.102:*) ;;
    *) die "LOCAL ONLY: LIVE_P2P=$LIVE_P2P is not LAN hub" ;;
  esac
}

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# v6.2 query CLIs can mix logs on stdout; jq/python on that is a silent pipefail
# (2026-09-14 cron: version=unknown then EXIT, no ERROR line, no pack).
extract_json() {
  python3 -c '
import json, sys
s = sys.stdin.read()
for i, ch in enumerate(s):
    if ch in "{[":
        json.dump(json.loads(s[i:]), sys.stdout)
        sys.exit(0)
sys.exit(1)
'
}

query_json() {
  local raw
  [[ -n "$QUERY_BIN" && -x "$QUERY_BIN" ]] || die "QUERY_BIN missing for query: $*"
  raw="$("$QUERY_BIN" "$@" --log_level error -o json 2>/dev/null)" || return 1
  printf '%s' "$raw" | extract_json
}

status_json() {
  curl -sfS -m 8 "$1/status"
}

height_of() {
  status_json "$1" | jq -r '.result.sync_info.latest_block_height'
}

catching_up() {
  status_json "$1" | jq -r '.result.sync_info.catching_up'
}

set_toml() {
  local file="$1" section="$2" key="$3" value="$4"
  python3 - "$file" "$section" "$key" "$value" <<'PY'
import sys
path, section, key, value = sys.argv[1:]
text = open(path).read()
lines = text.splitlines(True)
out, in_sec, replaced = [], False, False
for line in lines:
    if line.startswith("["):
        in_sec = line.strip() == f"[{section}]"
    if in_sec and (line.startswith(f"{key} ") or line.startswith(f"{key}=")):
        out.append(f"{key} = {value}\n")
        replaced = True
        continue
    out.append(line)
if not replaced:
    sys.exit(f"missing {section}.{key} in {path}")
open(path, "w").write("".join(out))
PY
}

# Live upgrades are Cosmovisor's job. Ephemeral pruned node is a *copy* of the
# binary Cosmovisor (or systemd) is currently running — never `cosmovisor run`.
resolve_live_binary() {
  local cv n pid exe cmd
  RESOLVED_BIN=""
  BIN_SOURCE=""
  cv="$LIVE_HOME/cosmovisor/current/bin"
  if [[ -d "$cv" ]]; then
    for n in "$DAEMON_NAME" terpd terpd-mainnet; do
      if [[ -x "$cv/$n" ]]; then
        RESOLVED_BIN="$(readlink -f "$cv/$n")"
        BIN_SOURCE="cosmovisor-current"
        return 0
      fi
    done
  fi
  for pid in $(ps -eo pid=); do
    [[ -r "/proc/$pid/cmdline" ]] || continue
    cmd="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
    [[ "$cmd" == *" start "* ]] || continue
    [[ "$cmd" == *"--home $LIVE_HOME"* || "$cmd" == *"--home=$LIVE_HOME"* ]] || continue
    exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
    [[ -n "$exe" && -x "$exe" ]] || continue
    [[ "$exe" == *cosmovisor* ]] && continue
    RESOLVED_BIN="$exe"
    BIN_SOURCE="proc-exe:$pid"
    return 0
  done
  if [[ -x "$LIVE_BIN" ]]; then
    RESOLVED_BIN="$LIVE_BIN"
    BIN_SOURCE="LIVE_BIN"
    return 0
  fi
  die "no live terpd binary (no cosmovisor/current, no process --home $LIVE_HOME, LIVE_BIN=$LIVE_BIN)"
}

stage_eph_binary() {
  local dest
  resolve_live_binary
  dest="$EPOCH_ROOT/bin/terpd"
  mkdir -p "$EPOCH_ROOT/bin"
  cp -L "$RESOLVED_BIN" "$dest"
  chmod +x "$dest"
  EPH_BIN="$dest"
  QUERY_BIN="$dest"
  log "staged eph binary src=$RESOLVED_BIN source=$BIN_SOURCE dest=$dest sha256=$(sha256sum "$dest" | awk '{print $1}')"
}

ensure_live() {
  local h applied cw hm ver
  h="$(height_of "$LIVE_RPC")" || die "live RPC down at $LIVE_RPC"
  [[ "$(catching_up "$LIVE_RPC")" == "false" ]] || die "live node catching_up=true"
  ver="$("$QUERY_BIN" version --log_level error 2>/dev/null | tail -n1 | tr -d '\r' | awk '{print $1}')"
  [[ -n "$ver" ]] || ver="$("$QUERY_BIN" version 2>/dev/null | tail -n1 | tr -d '\r' | awk '{print $1}')"
  log "live $CHAIN_ID height=$h rpc=$LIVE_RPC bin=$QUERY_BIN source=$BIN_SOURCE version=${ver:-unknown}"
  [[ "$h" -ge "$V6_HALT_HEIGHT" ]] || die "live height $h < v6 halt $V6_HALT_HEIGHT — refusing 5.2.0-era pack"
  applied="$(query_json q upgrade applied v6 --node "$LIVE_RPC" | jq -r '.height // empty')" \
    || die "q upgrade applied v6 failed (bin=$QUERY_BIN node=$LIVE_RPC)"
  [[ -n "$applied" ]] || die "upgrade applied v6 height empty (want $V6_HALT_HEIGHT)"
  [[ "$applied" == "$V6_HALT_HEIGHT" || "$applied" -ge "$V6_HALT_HEIGHT" ]] || \
    die "upgrade applied v6 height='$applied' (want $V6_HALT_HEIGHT)"
  read -r cw hm <<<"$(module_store_versions "$LIVE_RPC")" \
    || die "q upgrade module_versions failed"
  [[ "$cw" != "0" && -n "$cw" ]] || die "live cw-hooks store version is 0/empty"
  [[ "$hm" != "0" && -n "$hm" ]] || die "live hashmerchant store version is 0/empty"
  log "v6 ok applied=$applied cw-hooks=$cw hashmerchant=$hm"
}

module_store_versions() {
  local rpc="$1"
  query_json q upgrade module_versions --node "$rpc" | python3 -c '
import json,sys
j=json.load(sys.stdin)
d={m.get("name"): str(m.get("version","0")) for m in j.get("module_versions") or []}
print(d.get("cw-hooks","0"), d.get("hashmerchant","0"))
'
}

require_v6_stores() {
  local rpc="$1" where="$2"
  local cw hm
  read -r cw hm <<<"$(module_store_versions "$rpc")" \
    || die "$where q upgrade module_versions failed"
  log "$where cw-hooks=$cw hashmerchant=$hm"
  [[ "$cw" != "0" && -n "$cw" ]] || die "$where cw-hooks store version 0 — pack would fail v6.1 TSH"
  [[ "$hm" != "0" && -n "$hm" ]] || die "$where hashmerchant store version 0 — pack would fail v6.1 TSH"
}

start_live() {
  sudo -n systemctl start "$LIVE_UNIT"
  STOPPED_LIVE=0
  local i=0
  while ! height_of "$LIVE_RPC" >/dev/null 2>&1; do
    i=$((i + 1))
    [[ $i -lt 60 ]] || die "live RPC did not return after start"
    sleep 2
  done
  log "live restarted height=$(height_of "$LIVE_RPC")"
}

live_lock_held() {
  local f
  for f in \
    "$LIVE_HOME/data/application.db/LOCK" \
    "$LIVE_HOME/data/blockstore.db/LOCK" \
    "$LIVE_HOME/data/cs.wal/LOCK" \
    "$LIVE_HOME/wasm/exclusive.lock"
  do
    [[ -e "$f" ]] || continue
    lsof "$f" >/dev/null 2>&1 && return 0
  done
  return 1
}

stop_live() {
  log "stopping $LIVE_UNIT (local hub only — not Akash sentries)"
  sudo -n systemctl stop "$LIVE_UNIT"
  STOPPED_LIVE=1
  local i=0
  while pgrep -f -- "--home $LIVE_HOME" >/dev/null; do
    i=$((i + 1))
    [[ $i -lt 120 ]] || die "live process still running after stop"
    sleep 1
  done
  # LevelDB compaction can unlink files after the process is gone; rsync 24
  # (2026-09-13 archive) aborted the job via set -e and left a 98GiB eph home.
  i=0
  while live_lock_held; do
    i=$((i + 1))
    [[ $i -lt 30 ]] || die "live LevelDB LOCK still held after stop"
    sleep 1
  done
  sleep 5
  if pgrep -f -- "--home $LIVE_HOME" >/dev/null; then
    die "live process reappeared after stop drain"
  fi
  log "live drained (no --home $LIVE_HOME, no db LOCK)"
}

# PIDs whose argv contains this exact --home. Never LIVE_HOME (hub) or sentry homes.
eph_pids() {
  pgrep -f -- "--home ${EPH_HOME}" 2>/dev/null || true
}

eph_port_bound() {
  ss -lnt 2>/dev/null | grep -qE ":${EPH_RPC_PORT} |:${EPH_P2P_PORT} "
}

# Kill the statesync temp node and any children still bound to EPH_HOME.
# Leaked eph processes keep :27657 and look like extra "mainnet" terpds.
stop_eph() {
  local pids i
  if [[ -n "$EPH_PID" ]] && kill -0 "$EPH_PID" 2>/dev/null; then
    log "stopping ephemeral pid=$EPH_PID (process group)"
    kill -TERM -- "-$EPH_PID" 2>/dev/null || kill -TERM "$EPH_PID" 2>/dev/null || true
  fi
  pids="$(eph_pids)"
  if [[ -n "$pids" ]]; then
    log "reaping eph --home $EPH_HOME pids: $pids"
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null || true
  fi
  i=0
  while pids="$(eph_pids)"; [[ -n "$pids" ]]; do
    i=$((i + 1))
    if [[ $i -gt 20 ]]; then
      log "KILL leftover eph pids: $pids"
      # shellcheck disable=SC2086
      kill -KILL $pids 2>/dev/null || true
      # Last resort: only the eph ports, never live :26657.
      fuser -k "${EPH_RPC_PORT}/tcp" "${EPH_P2P_PORT}/tcp" >/dev/null 2>&1 || true
      break
    fi
    sleep 1
  done
  pids="$(eph_pids)"
  if [[ -n "$pids" ]]; then
    log "WARNING: eph still alive after KILL: $pids"
  else
    log "ephemeral home $EPH_HOME has no processes"
  fi
  EPH_PID=""
  rm -f "$EPOCH_ROOT/pruned.pid"
}

reclaim_eph_home() {
  [[ -d "$EPH_HOME" ]] || return 0
  if [[ -n "$(eph_pids)" ]]; then
    log "WARNING: not removing $EPH_HOME — processes still attached: $(eph_pids)"
    return 1
  fi
  if eph_port_bound; then
    log "WARNING: not removing $EPH_HOME — :${EPH_RPC_PORT}/:${EPH_P2P_PORT} still bound"
    return 1
  fi
  log "removing ephemeral home $EPH_HOME"
  rm -rf "$EPH_HOME"
}

cleanup() {
  local rc=$?
  stop_eph || true
  if [[ "$STOPPED_LIVE" == "1" ]]; then
    log "trap: restarting live node"
    start_live || log "trap: live restart failed"
  fi
  case "$CLASS" in
    pruned|archive|both|reap-only)
      reclaim_eph_home || true
      ;;
  esac
  exit "$rc"
}
trap cleanup EXIT

spawn_pruned() {
  local latest trust_h trust_hash
  latest="$(height_of "$LIVE_RPC")"
  trust_h=$(( (latest - TRUST_LAG) / 100 * 100 ))
  [[ "$trust_h" -gt 1 ]] || die "bad trust height $trust_h"
  trust_hash="$(curl -sfS -m 15 "$LIVE_RPC/block?height=$trust_h" | jq -r '.result.block_id.hash')"
  [[ -n "$trust_hash" && "$trust_hash" != "null" ]] || die "no trust hash at $trust_h"
  log "statesync trust_height=$trust_h hash=$trust_hash"

  # Reap leftovers BEFORE rm -rf home (open LevelDB from a leaked terpd would
  # survive and keep answering EPH_RPC — Sep 10 cron packed Sep 9's height).
  stop_eph
  if [[ -n "$(eph_pids)" ]]; then
    die "refusing spawn: leftover process still has --home $EPH_HOME"
  fi
  if eph_port_bound; then
    die "refusing spawn: ephemeral port ${EPH_RPC_PORT}/${EPH_P2P_PORT} still bound"
  fi

  rm -rf "$EPH_HOME"
  mkdir -p "$EPOCH_ROOT/logs"
  "$EPH_BIN" init snap-epoch --chain-id "$CHAIN_ID" --home "$EPH_HOME" --overwrite >/dev/null 2>/dev/null
  cp "$LIVE_HOME/config/genesis.json" "$EPH_HOME/config/genesis.json"

  set_toml "$EPH_HOME/config/config.toml" rpc laddr "\"tcp://127.0.0.1:${EPH_RPC_PORT}\""
  set_toml "$EPH_HOME/config/config.toml" p2p laddr "\"tcp://127.0.0.1:${EPH_P2P_PORT}\""
  set_toml "$EPH_HOME/config/config.toml" p2p external_address "\"\""
  set_toml "$EPH_HOME/config/config.toml" p2p seeds "\"\""
  set_toml "$EPH_HOME/config/config.toml" p2p persistent_peers "\"${LIVE_NODE_ID}@${LIVE_P2P}\""
  set_toml "$EPH_HOME/config/config.toml" p2p unconditional_peer_ids "\"${LIVE_NODE_ID}\""
  set_toml "$EPH_HOME/config/config.toml" p2p pex "false"
  set_toml "$EPH_HOME/config/config.toml" p2p addr_book_strict "false"
  set_toml "$EPH_HOME/config/config.toml" statesync enable "true"
  set_toml "$EPH_HOME/config/config.toml" statesync rpc_servers "\"${LIVE_RPC},${LIVE_RPC}\""
  set_toml "$EPH_HOME/config/config.toml" statesync trust_height "$trust_h"
  set_toml "$EPH_HOME/config/config.toml" statesync trust_hash "\"${trust_hash}\""
  set_toml "$EPH_HOME/config/config.toml" statesync trust_period "\"168h0m0s\""
  python3 - "$EPH_HOME/config/app.toml" <<'PY'
import sys, re
p = sys.argv[1]
t = open(p).read()
t = re.sub(r'(?m)^pruning\s*=.*', 'pruning = "everything"', t, count=1)
t = re.sub(r'(?m)^snapshot-interval\s*=.*', 'snapshot-interval = 0', t, count=1)
open(p, "w").write(t)
PY

  log "starting ephemeral home=$EPH_HOME bin=$EPH_BIN (not cosmovisor, setsid)"
  # Own session so TERM/KILL to the group reaps Comet children. Never Cosmovisor.
  setsid "$EPH_BIN" start --home "$EPH_HOME" \
    >"$EPOCH_ROOT/logs/pruned.log" 2>&1 &
  EPH_PID=$!
  echo "$EPH_PID" >"$EPOCH_ROOT/pruned.pid"
}

wait_statesync() {
  local start now h live
  start="$(date +%s)"
  while true; do
    now="$(date +%s)"
    if [[ $((now - start)) -gt $SYNC_TIMEOUT_SEC ]]; then
      tail -n 40 "$EPOCH_ROOT/logs/pruned.log" || true
      die "statesync timed out after ${SYNC_TIMEOUT_SEC}s"
    fi
    if ! kill -0 "$EPH_PID" 2>/dev/null; then
      tail -n 80 "$EPOCH_ROOT/logs/pruned.log" || true
      die "ephemeral process died"
    fi
    if h="$(height_of "$EPH_RPC" 2>/dev/null)"; then
      live="$(height_of "$LIVE_RPC")"
      log "ephemeral height=$h catching_up=$(catching_up "$EPH_RPC" 2>/dev/null || echo '?') live=$live"
      if [[ "$(catching_up "$EPH_RPC")" == "false" ]] && [[ "$h" -ge $((live - 20)) ]]; then
        [[ "$h" -ge "$V6_HALT_HEIGHT" ]] || die "ephemeral height $h < v6 halt $V6_HALT_HEIGHT"
        require_v6_stores "$EPH_RPC" "ephemeral"
        log "ephemeral caught up at $h (post-v6 stores)"
        return 0
      fi
    else
      log "waiting for ephemeral RPC"
    fi
    sleep 15
  done
}

# Only ${CHAIN_ID}_*.tar.lz4 in this class. Never snapshot.json / genesis / scripts / state.json.
delete_class_tarballs() {
  local class="$1"
  local keep="${2:-}"
  local dir="${MC_ALIAS}/${PREFIX}/${class}"
  local f
  [[ "$DRY_RUN" == "1" ]] && { log "DRY_RUN skip delete in $dir"; return 0; }
  mapfile -t list < <(mc ls "$dir/" 2>/dev/null | awk '{print $NF}' | grep '\.tar\.lz4$' || true)
  for f in "${list[@]}"; do
    [[ "$f" == "${CHAIN_ID}_"*".tar.lz4" ]] || { log "skip non-allowlist $f"; continue; }
    [[ -n "$keep" && "$f" == "$keep" ]] && continue
    log "delete class tar: ${dir}/${f}"
    mc rm --force "${dir}/${f}" >/dev/null
  done
}

require_published() {
  local dest="$1" public_url="$2"
  local code
  mc stat "$dest" >/dev/null 2>&1 || die "mc stat not ok: $dest — JSON unchanged"
  code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 12 -m 20 -I "$public_url" || true)"
  [[ "$code" == "200" ]] || die "public HEAD $code (need 200) $public_url — JSON unchanged"
}

s3_put_tree() {
  local class="$1" height="$2"
  local ts dest name url
  ts="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
  name="${CHAIN_ID}_${height}_${ts}.tar.lz4"
  dest="${MC_ALIAS}/${PREFIX}/${class}/${name}"
  url="${PUBLIC_BASE}/${PREFIX}/${class}/${name}"
  log "upload $dest (data+wasm only)"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN skip upload $name"
    printf '%s\n' "$url"
    return 0
  fi
  # Archive ~54GiB vs MinIO /data often <54GiB free: drop previous archive tar first.
  # Pruned ~390MiB: keep the old tar until the new object publishes so a failed pipe
  # cannot empty the class (2026-08-28 cron wiped latest by deleting first).
  if [[ "$class" == "archive" ]]; then
    delete_class_tarballs "$class"
  fi
  # wasm/cache is Wasmer compiled modules (CPU + libwasmvm specific). Shipping it
  # caused a v6.0.1 validator gas/apphash stall after loading our public snapshot.
  # Consensus wasm lives in data/ + wasm/state (+ wasm/wasm). Recipients rebuild cache.
  if ! tar -C "$EPH_HOME" --exclude='wasm/cache' --exclude='wasm/exclusive.lock' \
       -cf - data wasm | lz4 -c | mc pipe "$dest" >/dev/null; then
    die "mc pipe failed for $dest — snapshot.json left unchanged"
  fi
  require_published "$dest" "$url"
  if [[ "$class" != "archive" ]]; then
    delete_class_tarballs "$class" "$name"
  fi
  printf '%s\n' "$url"
}

write_manifest() {
  local class="$1" latest_url="$2"
  local dir tmp list n
  dir="${MC_ALIAS}/${PREFIX}/${class}"
  tmp="$(mktemp)"
  if [[ "$DRY_RUN" == "1" ]]; then
    jq -n --arg c "$CHAIN_ID" --arg l "$latest_url" \
      '{chain_id:$c, snapshots:[$l], latest:$l}' >"$tmp"
    log "DRY_RUN manifest $(cat "$tmp")"
    rm -f "$tmp"
    return 0
  fi
  [[ "$latest_url" == https://* ]] || die "refusing ${class} snapshot.json: latest is not https"
  require_published "${MC_ALIAS}/${latest_url#${PUBLIC_BASE}/}" "$latest_url"
  mapfile -t list < <(mc ls "$dir/" | awk '{print $NF}' | grep '\.tar\.lz4$' | sort || true)
  python3 - "$CHAIN_ID" "$PUBLIC_BASE/$PREFIX/$class" "$tmp" "${list[@]}" <<'PY'
import json, sys
chain, base, out = sys.argv[1], sys.argv[2].rstrip("/"), sys.argv[3]
files = sys.argv[4:]
urls = [f"{base}/{f}" for f in files]
latest = urls[-1] if urls else ""
json.dump({"chain_id": chain, "snapshots": urls, "latest": latest}, open(out, "w"))
PY
  mc cp "$tmp" "${dir}/snapshot.json"
  rm -f "$tmp"
  log "wrote ${dir}/snapshot.json latest=$latest_url"
}

patch_root_pointer() {
  local file="$1" url="$2" height="$3"
  local tmp remote
  # Callers may pass captured pipe noise; keep the last https URL line only.
  url="$(printf '%s\n' "$url" | grep '^https://' | tail -n1)"
  [[ -n "$url" ]] || { log "skip patch $file: no https url"; return 0; }
  remote="${MC_ALIAS}/${PREFIX}/${file}"
  tmp="$(mktemp)"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN skip patch $file -> $url"
    rm -f "$tmp"
    return 0
  fi
  if mc cat "$remote" >"$tmp" 2>/dev/null; then
    SNAP_URL="$url" SNAP_HEIGHT="$height" python3 - "$tmp" <<'PY'
import json, os, sys, datetime
path = sys.argv[1]
url, height = os.environ["SNAP_URL"], os.environ.get("SNAP_HEIGHT", "")
j = json.load(open(path))
j["latest"] = url
j["url"] = url
if height:
    j["block_height"] = int(height)
j["updated_at"] = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump(j, open(path, "w"), indent=2)
print("patched", path, "->", url, file=sys.stderr)
PY
  else
    jq -n --arg c "$CHAIN_ID" --arg l "$url" '{chain_id:$c, snapshots:[$l], latest:$l}' >"$tmp"
  fi
  mc cp "$tmp" "$remote"
  rm -f "$tmp"
}

rsync_halt_copy() {
  local src="$1" dest="$2"
  shift 2
  local try rc=0
  mkdir -p "$dest"
  for try in 1 2 3; do
    set +e
    rsync -a --delete "$@" "$src" "$dest"
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      return 0
    fi
    if [[ $rc -eq 24 ]]; then
      log "rsync vanished-files (24) try=$try $src — drain and retry"
      sleep 5
      if pgrep -f -- "--home $LIVE_HOME" >/dev/null; then
        die "live process running during archive rsync — abort (would pack a moving tree)"
      fi
      continue
    fi
    die "rsync failed rc=$rc $src -> $dest"
  done
  die "rsync still code 24 after 3 tries $src -> $dest"
}

copy_data_wasm() {
  local need have eph extra
  need="$(du -sb "$LIVE_HOME/data" | awk '{print $1}')"
  if [[ -d "$LIVE_HOME/wasm" ]]; then
    need=$((need + $(du -sb "$LIVE_HOME/wasm" | awk '{print $1}')))
  fi
  have="$(df -B1 --output=avail /storage | tail -1 | tr -d ' ')"
  eph=0
  if [[ -d "$EPH_HOME" ]]; then
    eph="$(du -sb "$EPH_HOME" | awk '{print $1}')"
  fi
  extra="$need"
  if [[ "$eph" -gt 0 && "$eph" -lt "$need" ]]; then
    extra=$((need - eph))
  elif [[ "$eph" -ge "$need" ]]; then
    extra=0
  fi
  log "copy need_bytes=$need eph_bytes=$eph extra=$extra storage_avail=$have"
  [[ "$have" -gt "$extra" ]] || \
    die "not enough /storage for archive copy (avail=$have extra=$extra) — reap EPH_HOME first"
  mkdir -p "$EPH_HOME/data"
  rsync_halt_copy "$LIVE_HOME/data/" "$EPH_HOME/data/"
  if [[ -d "$LIVE_HOME/wasm" ]]; then
    rsync_halt_copy "$LIVE_HOME/wasm/" "$EPH_HOME/wasm/" --exclude cache/ --exclude exclusive.lock
  fi
}

# --- main ---
command -v jq >/dev/null || die "need jq"
command -v lz4 >/dev/null || die "need lz4"
command -v mc >/dev/null || die "need mc"
command -v python3 >/dev/null || die "need python3"
mkdir -p "$EPOCH_ROOT"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  die "another curate-epoch holds $LOCK_FILE"
fi
if [[ "$CLASS" == "reap-only" ]]; then
  stop_eph
  leftover="$(eph_pids)"
  if [[ -n "$leftover" ]]; then
    die "reap-only: still running: $leftover"
  fi
  if eph_port_bound; then
    die "reap-only: :${EPH_RPC_PORT}/:${EPH_P2P_PORT} still bound"
  fi
  log "reap-only ok — no process has --home $EPH_HOME"
  exit 0
fi
stage_eph_binary
[[ -x "$EPH_BIN" ]] || die "staged binary missing $EPH_BIN"
if [[ "$CLASS" == "resolve-only" ]]; then
  log "resolve-only ok"
  exit 0
fi
ensure_live
assert_local_hub

PRUNED_URL=""
ARCHIVE_URL=""
if [[ "$CLASS" == "pruned" || "$CLASS" == "both" ]]; then
  log "=== pruned statesync CLASS=$CLASS ==="
  spawn_pruned
  wait_statesync
  PRUNED_H="$(height_of "$EPH_RPC")"
  stop_eph
  if [[ -n "$(eph_pids)" ]]; then
    die "ephemeral still running after stop_eph — not packing a live temp node"
  fi
  PRUNED_URL="$(s3_put_tree pruned "$PRUNED_H" | grep '^https://' | tail -n1)"
  [[ "$PRUNED_URL" == https://* ]] || die "pruned upload produced no URL — JSON unchanged"
  write_manifest pruned "$PRUNED_URL"
  patch_root_pointer snapshot_light.json "$PRUNED_URL" "$PRUNED_H"
fi

if [[ "$CLASS" == "archive" || "$CLASS" == "both" ]]; then
  if [[ "${OLINE_DANGER_HALT_LIVE:-0}" != "1" ]]; then
    die "CLASS=$CLASS would stop $LIVE_UNIT (host-rpc). Public sentries statesync from that hub. Set OLINE_DANGER_HALT_LIVE=1 to halt-copy anyway."
  fi
  log "=== archive halt-copy-resume ==="
  ARCHIVE_H="$(height_of "$LIVE_RPC")"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN skip live halt (would snapshot height=$ARCHIVE_H)"
  else
    stop_live
    copy_data_wasm
    start_live
  fi
  ARCHIVE_URL="$(s3_put_tree archive "$ARCHIVE_H" | grep '^https://' | tail -n1)"
  [[ "$ARCHIVE_URL" == https://* ]] || die "archive upload produced no URL — JSON unchanged"
  write_manifest archive "$ARCHIVE_URL"
  patch_root_pointer snapshot.json "$ARCHIVE_URL" "$ARCHIVE_H"
  patch_root_pointer snapshot_full.json "$ARCHIVE_URL" "$ARCHIVE_H"
fi

log "done pruned=$PRUNED_URL archive=$ARCHIVE_URL"
log "live height=$(height_of "$LIVE_RPC") catching_up=$(catching_up "$LIVE_RPC")"
