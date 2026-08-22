#!/usr/bin/env bash
# Rewrite terp-prebuilt.env and ict-rs-bins.env to the newest commit folder
# on MinIO (max LastModified under releases/{terp-core,ict-rs}/commits/).
# Does not upload. Does not git commit.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOST="${PREBUILT_HOST:-https://minio.terp.network}"

python3 - "$ROOT" "$HOST" <<'PY'
import re, sys, urllib.request
from pathlib import Path

root, host = Path(sys.argv[1]), sys.argv[2].rstrip("/")

def list_keys(prefix: str) -> list[tuple[str, str]]:
    url = f"{host}/releases/?list-type=2&prefix={prefix}"
    xml = urllib.request.urlopen(url, timeout=60).read().decode()
    keys = re.findall(r"<Key>(.*?)</Key>", xml)
    mods = re.findall(r"<LastModified>(.*?)</LastModified>", xml)
    return list(zip(keys, mods))

def latest_commit(prefix: str) -> tuple[str, str]:
    best_sha, best_mod = "", ""
    for key, mod in list_keys(prefix):
        rest = key[len(prefix):]
        sha = rest.split("/", 1)[0]
        if len(sha) != 40:
            continue
        if mod >= best_mod:
            best_mod, best_sha = mod, sha
    if not best_sha:
        raise SystemExit(f"no commit folders under {prefix}")
    return best_sha, best_mod

terp_sha, terp_mod = latest_commit("terp-core/commits/")
ict_sha, ict_mod = latest_commit("ict-rs/commits/")
print(f"terp-core {terp_sha} LastModified={terp_mod}")
print(f"ict-rs    {ict_sha} LastModified={ict_mod}")

(root / "scripts/ci/terp-prebuilt.env").write_text(
    "# Terp-core image/binary this E2E loads. Keyed like terp-core/commits/<sha>/.\n"
    "# Move this only after publishing that SHA to MinIO (scripts/ci/pin-latest-prebuilts.sh).\n"
    f"# Latest object on minio.terp.network as of pin: LastModified {terp_mod[:10]}.\n"
    f"PREBUILT_COMMIT={terp_sha}\n"
    "PREBUILT_HOST=https://minio.terp.network\n"
)
tarball = "ict-ci-linux-x86_64.tar.gz"
(root / "scripts/ci/ict-rs-bins.env").write_text(
    "# ict-rs prebuilts keyed by ict-rs git SHA (mirror terp-core/commits/<sha>/).\n"
    "# This SHA is the tree that produced dist/ict-ci-linux-x86_64.tar.gz.\n"
    "# Move this only after publishing that SHA (scripts/ci/pin-latest-prebuilts.sh).\n"
    f"# Latest object on minio.terp.network as of pin: LastModified {ict_mod[:10]}.\n"
    "ICT_RS_PROJECT=ict-rs\n"
    f"ICT_RS_COMMIT={ict_sha}\n"
    f"ICT_RS_TARBALL={tarball}\n"
    f"ICT_RS_BINS_URL=https://minio.terp.network/releases/ict-rs/commits/{ict_sha}/{tarball}\n"
)
print("wrote scripts/ci/terp-prebuilt.env")
print("wrote scripts/ci/ict-rs-bins.env")
PY
