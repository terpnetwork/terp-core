"""
Usage:
This script generates a JSON object containing binary download URLs and their corresponding checksums
for a given release tag of terpnetwork/terp-core or from a provided checksum file/URL.
The binary JSON is compatible with cosmovisor and with the chain registry.

When --tag is provided, the script first checks build/sha256sum.txt locally (useful before
the GitHub release exists), then falls back to fetching from GitHub.

❯ python create_binaries_json.py --tag v5.1.0

Output:
{
  "binaries": {
    "linux/amd64": "https://s3.terp.network/releases/terp-core/v5.1.0/terpd-5.1.0-linux-amd64.tar.gz?checksum=sha256:<checksum>",
    "linux/arm64": "https://s3.terp.network/releases/terp-core/v5.1.0/terpd-5.1.0-linux-arm64.tar.gz?checksum=sha256:<checksum>",
    "darwin/arm64": "https://s3.terp.network/releases/terp-core/v5.1.0/terpd-5.1.0-darwin-arm64.tar.gz?checksum=sha256:<checksum>",
  }
}

Expects a checksum file in the form:

<CHECKSUM>  terpd-<VERSION>-<OS>-<ARCH>.tar.gz
<CHECKSUM>  terpd-<VERSION>-<OS>-<ARCH>.tar.gz
...

Example (build/sha256sum.txt after `make release-prep`):

e3b0c44298fc1c149afbf4c8996fb924  terpd-linux-amd64
a9f03741ac976173365198c0b10ff54f  terpd-linux-arm64
f838618633c1d42f593dc33d26b25842  terpd-5.1.0-linux-amd64.tar.gz
ac427205954409139f7c11252ee0e47e  terpd-5.1.0-linux-arm64.tar.gz
"""

import os
import requests
import json
import argparse
import re
import sys

LOCAL_CHECKSUMS_PATH = "build/sha256sum.txt"


def validate_tag(tag):
    # vX.Y.Z plus optional prerelease (v6.1.0-dev)
    pattern = r'^v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.]+)?$'
    return bool(re.match(pattern, tag))


def read_local_checksums(path):
    with open(path, "r") as f:
        return f.read()


def download_checksums(url):
    response = requests.get(url)
    if response.status_code != 200:
        raise ValueError(f"Failed to fetch sha256sum.txt from {url}. Status code: {response.status_code}")
    return response.text


def get_checksums(tag=None, checksums_url=None):
    """
    Resolution order when --tag is given:
      1. build/sha256sum.txt (local, pre-publish)
      2. GitHub release URL (post-publish)
    When --checksums_url is given, fetch directly.
    """
    if checksums_url:
        return download_checksums(checksums_url)

    if os.path.exists(LOCAL_CHECKSUMS_PATH):
        print(f"Using local checksums from {LOCAL_CHECKSUMS_PATH}", file=sys.stderr)
        return read_local_checksums(LOCAL_CHECKSUMS_PATH)

    s3_url = f"https://s3.terp.network/releases/terp-core/{tag}/sha256sum.txt"
    print(f"Local {LOCAL_CHECKSUMS_PATH} not found, fetching from {s3_url}", file=sys.stderr)
    return download_checksums(s3_url)


TARBALL_RE = re.compile(
    r"^terpd-(.+)-(linux|darwin|windows)-(amd64|arm64)(?:-cv)?\.tar\.gz$"
)


def checksums_to_binaries_json(checksums, tag, base_url=None):
    binaries = {}
    base_url = (base_url or f"https://s3.terp.network/releases/terp-core/{tag}").rstrip("/")

    for line in checksums.splitlines():
        line = line.strip()
        if not line:
            continue

        parts = line.split("  ", 1)
        if len(parts) != 2:
            continue
        checksum, filename = parts
        filename = os.path.basename(filename)

        # Only process versioned tarballs — these are what get uploaded to s3.terp.network
        if not filename.endswith(".tar.gz") or not filename.startswith("terpd-"):
            continue

        m = TARBALL_RE.match(filename)
        if not m:
            print(f"Warning: skipping unexpected filename format: {filename}", file=sys.stderr)
            continue

        _version, platform, arch = m.group(1), m.group(2), m.group(3)
        if arch == "all" or platform == "windows":
            continue

        url = f"{base_url}/{filename}?checksum=sha256:{checksum}"
        binaries[f"{platform}/{arch}"] = url

    if not binaries:
        print("Error: no matching tarball entries found in checksums file.", file=sys.stderr)
        sys.exit(1)

    return json.dumps({"binaries": binaries}, indent=2) + "\n"


def main():
    parser = argparse.ArgumentParser(description="Generate cosmovisor-compatible binaries JSON")
    parser.add_argument('--tag', type=str, help='Release tag (e.g. v5.1.0 or v6.1.0-dev)')
    parser.add_argument('--checksums_url', type=str, help='Direct URL to sha256sum.txt')
    parser.add_argument('--checksums_file', type=str, help='Local sha256sum.txt (overrides build/sha256sum.txt)')
    parser.add_argument('--base-url', type=str, dest='base_url', help='Prefix for tarball URLs')
    parser.add_argument('--out', type=str, help='Write JSON to this path instead of stdout')
    args = parser.parse_args()

    if args.tag and not validate_tag(args.tag):
        print("Error: tag must follow 'vX.Y.Z' or 'vX.Y.Z-prerelease'.")
        sys.exit(1)

    sources = [bool(args.tag), bool(args.checksums_url)]
    if sum(sources) != 1:
        parser.error("Specify exactly one of --tag or --checksums_url")

    tag = args.tag
    if args.checksums_file:
        checksums = read_local_checksums(args.checksums_file)
    else:
        checksums = get_checksums(tag=tag, checksums_url=args.checksums_url)
    binaries_json = checksums_to_binaries_json(checksums, tag, base_url=args.base_url)
    if args.out:
        with open(args.out, "w") as f:
            f.write(binaries_json)
        print(f"wrote {args.out}", file=sys.stderr)
    else:
        print(binaries_json, end="")


if __name__ == "__main__":
    main()
