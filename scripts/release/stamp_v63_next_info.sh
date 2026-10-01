#!/usr/bin/env bash
# Stamp app/upgrades/v6_3/constants.go NextUpgradeInfo from v6.4 cosmovisor.json.
# Cosmovisor reads plan.info as this compact JSON (binaries + sha256), not a bare URL.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CJ="$ROOT/networks/upgrades/v6.4/cosmovisor.json"
GO="$ROOT/app/upgrades/v6_3/constants.go"
[ -f "$CJ" ] || { echo "ERROR: missing $CJ (WRITE=1 PLAN=v6.4 sync-upgrade-pack first)" >&2; exit 1; }
compact="$(jq -c . "$CJ")"
echo "$compact" | jq -e '.binaries["linux/amd64"] | test("checksum=sha256:[0-9a-f]{64}")' >/dev/null
echo "$compact" | jq -e '.binaries["linux/arm64"] | test("checksum=sha256:[0-9a-f]{64}")' >/dev/null
python3 - "$GO" "$compact" <<'PY'
import pathlib, re, sys
path, compact = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text()
# Keep a single-line raw string so Cosmovisor/JSON stay byte-identical to jq -c.
pat = re.compile(
    r"const NextUpgradeInfo = `[^`]*`",
    re.S,
)
repl = "const NextUpgradeInfo = `" + compact.replace("`", "") + "`"
if not pat.search(text):
    sys.exit("ERROR: NextUpgradeInfo const not found in " + str(path))
path.write_text(pat.sub(repl, text, count=1))
print("stamped NextUpgradeInfo from v6.4/cosmovisor.json")
print(compact)
PY
