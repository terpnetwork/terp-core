#!/usr/bin/env bash
# Fail-closed hasher packaging for feat/6.3.0-dev. Does not touch v6.1/v6.2 packs.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail() { echo "ERROR: $*" >&2; exit 1; }

grep -q 'github.com/cosmos/iavl => github.com/permissionlessweb/iavl' go.mod \
  || fail "go.mod missing replace iavl => permissionlessweb/iavl"
grep -q 'github.com/cosmos/cosmos-sdk/store/v2 => github.com/permissionlessweb/cosmos-sdk/store/v2' go.mod \
  || fail "go.mod missing replace store/v2 => permissionlessweb/cosmos-sdk/store/v2"
grep -q 'github.com/cosmos/ics23/go => github.com/permissionlessweb/ics23/go' go.mod \
  || fail "go.mod missing replace ics23 => permissionlessweb/ics23/go"
echo "OK hasher packaging (fork replaces, not vendored trees)"
