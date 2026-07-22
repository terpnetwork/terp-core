#!/usr/bin/env bash
# Zakura local for Private Bridge (D6) — health + receive dest for UI / harness.
#
# Usage:
#   ./zakura-local.sh status|up|down|dest|rpc-smoke|golden
#
# Env:
#   ZAKURA_RPC          default http://127.0.0.1:18232
#   ZAKURA_DEST_ADDR    override dest (else regtest miner_address)
#   ZAKURAD_BIN         path to host-built Linux-compatible zakurad
#
# Honest: regtest only — not mainnet ZEC send.
# Golden vector: golden-dest-binding.json (domain terp-dest-binding-v0).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
MONOREPO="$(cd "$ROOT/../../../../.." && pwd)"
ZAKURA_REPO="${ZAKURA_REPO:-$MONOREPO/crates/zakura}"
COMPOSE="$ROOT/docker-compose.corridor-zakura.yml"
GOLDEN="$ROOT/golden-dest-binding.json"
ZAKURA_RPC="${ZAKURA_RPC:-http://127.0.0.1:18232}"
# Matches node-corridor.toml miner_address (regtest transparent)
DEFAULT_DEST="tmJymvcUCn1ctbghvTJpXBwHiMEB8P6wxNV"
DEST="${ZAKURA_DEST_ADDR:-$DEFAULT_DEST}"

cmd="${1:-status}"

rpc() {
  local method="$1" params="${2:-[]}"
  curl -sf --max-time 5 -X POST "$ZAKURA_RPC/" \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}"
}

rpc_ready() {
  rpc getblockchaininfo 2>/dev/null | grep -q '"result"'
}

owner_binding_hex() {
  # Same domain as PrivateCorridor UI mock.ts: terp-dest-binding-v0|<display>
  local addr="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    printf 'terp-dest-binding-v0|%s' "$addr" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf 'terp-dest-binding-v0|%s' "$addr" | shasum -a 256 | awk '{print $1}'
  else
    python3 -c "import hashlib,sys; print(hashlib.sha256(('terp-dest-binding-v0|'+sys.argv[1]).encode()).hexdigest())" "$addr"
  fi
}

ensure_bin() {
  if [[ -n "${ZAKURAD_BIN:-}" && -x "${ZAKURAD_BIN}" ]]; then
    return 0
  fi
  if [[ "$(uname -s)" == "Darwin" ]]; then
    # Docker Desktop needs a Linux binary (same residual as zakura-regtest-e2e).
    local cached="$ZAKURA_REPO/target/zakura-corridor-linux/zakurad"
    if [[ -x "$cached" ]]; then
      export ZAKURAD_BIN="$cached"
      return 0
    fi
    echo "macOS: build Linux zakurad for Docker (or set ZAKURAD_BIN to a Linux binary)."
    echo "  Full path: crates/zakura/docker/zakura-regtest-e2e/run.sh builds via ubuntu-package.Dockerfile"
    echo "  Or: docker pull zakuracore/zakura:latest and use official image docs in README"
    return 1
  fi
  local host_bin="$ZAKURA_REPO/target/debug/zakurad"
  if [[ ! -x "$host_bin" ]]; then
    echo "building host zakurad (debug) — regtest only"
    (cd "$ZAKURA_REPO" && CXXFLAGS="${CXXFLAGS:--include cstdint}" cargo build -p zakura --bin zakurad)
  fi
  [[ -x "$host_bin" ]] || { echo "zakurad missing at $host_bin"; return 1; }
  export ZAKURAD_BIN="$host_bin"
}

case "$cmd" in
  status)
    if rpc_ready; then
      echo "OK Zakura RPC $ZAKURA_RPC"
      rpc getblockchaininfo | head -c 400
      echo
      exit 0
    fi
    echo "Zakura RPC not ready at $ZAKURA_RPC"
    exit 1
    ;;

  up)
    if rpc_ready; then
      echo "already up at $ZAKURA_RPC"
      exit 0
    fi
    ensure_bin || exit 1
    command -v docker >/dev/null || { echo "docker required for up"; exit 1; }
    echo "starting corridor-zakura (ZAKURAD_BIN=$ZAKURAD_BIN)"
    docker compose -f "$COMPOSE" up -d
    for i in $(seq 1 60); do
      if rpc_ready; then
        echo "RPC ready after ${i}s"
        exit 0
      fi
      sleep 1
    done
    echo "timeout waiting for RPC"; docker compose -f "$COMPOSE" logs --tail=40 || true
    exit 1
    ;;

  down)
    docker compose -f "$COMPOSE" down --remove-orphans --timeout 5 2>/dev/null || true
    echo "down"
    ;;

  dest)
    # Prefer live validate when RPC up; always print dest + owner_binding for UI
    if rpc_ready; then
      val="$(rpc validateaddress "[\"$DEST\"]" 2>/dev/null || true)"
      if echo "$val" | grep -q '"isvalid"[[:space:]]*:[[:space:]]*true'; then
        echo "rpc_validated=true"
      else
        echo "rpc_validated=false (address may still be usable for lab preauth digest)"
        echo "$val" | head -c 200 || true
        echo
      fi
      chain="$(rpc getblockchaininfo 2>/dev/null | grep -oE '"chain"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 || true)"
      echo "chain_info=$chain"
    else
      echo "rpc_ready=false (offline dest from config / ZAKURA_DEST_ADDR)"
    fi
    echo "dest_display=$DEST"
    echo "owner_binding=$(owner_binding_hex "$DEST")"
    echo "domain=terp-dest-binding-v0"
    echo "ui: paste dest_display into PrivateCorridor ZEC dest step"
    echo "env: ZAKURA_RPC=$ZAKURA_RPC ZAKURA_DEST_ADDR=\$dest_display"
    ;;

  rpc-smoke)
    rpc_ready || { echo "FAIL: RPC down — run: $0 up"; exit 1; }
    echo "== getblockchaininfo =="
    rpc getblockchaininfo | head -c 500
    echo
    echo "== validateaddress $DEST =="
    rpc validateaddress "[\"$DEST\"]" | head -c 500
    echo
    echo "== dest / owner_binding =="
    bash "$0" dest
    echo "OK zakura rpc-smoke"
    ;;

  golden)
    # Verify every sample in golden-dest-binding.json against shell SHA-256
    # (same preimage as UI mock.ts + harness zakura_local.rs).
    [[ -f "$GOLDEN" ]] || { echo "FAIL: missing $GOLDEN"; exit 1; }
    if ! command -v python3 >/dev/null 2>&1; then
      # Minimal fallback: primary miner dest only
      expected="8b5cac11e39905d56126a0c538b84ff8daa379d8009d4e8b121112479607f09b"
      got="$(owner_binding_hex "$DEFAULT_DEST")"
      [[ "$got" == "$expected" ]] || {
        echo "FAIL primary golden: got=$got expected=$expected"
        exit 1
      }
      echo "OK golden primary (python3 absent; miner sample only)"
      echo "domain=terp-dest-binding-v0"
      echo "dest_display=$DEFAULT_DEST"
      echo "owner_binding=$got"
      exit 0
    fi
    python3 - "$GOLDEN" <<'PY'
import hashlib, json, sys
path = sys.argv[1]
doc = json.load(open(path))
domain = doc["domain"]
sep = doc.get("preimage_separator", "|")
assert domain == "terp-dest-binding-v0", domain
failed = 0
for s in doc["samples"]:
    dest = s["dest_display"].strip()
    pre = f"{domain}{sep}{dest}".encode()
    got = hashlib.sha256(pre).hexdigest()
    exp = s["owner_binding_hex"].lower()
    ok = got == exp
    print(f"{'OK' if ok else 'FAIL'} id={s['id']} dest={dest}")
    print(f"  owner_binding={got}")
    if not ok:
        print(f"  expected     ={exp}")
        failed += 1
primary = next(s for s in doc["samples"] if s.get("primary"))
print(f"primary={primary['id']} domain={domain}")
print(f"rpc.default_url={doc.get('rpc', {}).get('default_url', '')}")
sys.exit(1 if failed else 0)
PY
    echo "OK golden-dest-binding.json parity"
    ;;

  -h|--help|help)
    sed -n '2,20p' "$0"
    ;;

  *)
    echo "unknown cmd: $cmd (status|up|down|dest|rpc-smoke|golden)" >&2
    exit 2
    ;;
esac
