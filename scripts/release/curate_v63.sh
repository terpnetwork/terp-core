#!/usr/bin/env bash
# Fail-closed hasher packaging for feat/6.3.0-dev. Does not touch v6.1/v6.2 packs.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail() { echo "ERROR: $*" >&2; exit 1; }

grep -q 'github.com/cosmos/iavl => ./crates/cosmos/iavl' go.mod \
  || fail "go.mod missing replace github.com/cosmos/iavl => ./crates/cosmos/iavl"
grep -q 'github.com/cosmos/cosmos-sdk/store/v2 => ./crates/cosmos/store-v2' go.mod \
  || fail "go.mod missing replace store/v2 => ./crates/cosmos/store-v2"
test -f crates/cosmos/iavl/store_hasher.go || fail "crates/cosmos/iavl/store_hasher.go missing"
grep -q HasherOptionForStore crates/cosmos/iavl/store_hasher.go \
  || fail "HasherOptionForStore not in crates/cosmos/iavl"
grep -q HasherOptionForStore crates/cosmos/store-v2/iavl/store.go \
  || fail "store/v2 LoadStoreWithOpts missing HasherOptionForStore"

if command -v git >/dev/null; then
  git check-ignore -q crates/cosmos/iavl/store_hasher.go \
    && fail "crates/cosmos/iavl is gitignored — Docker recurate will miss hasher (v6.1 miss)"
  git check-ignore -q crates/cosmos/store-v2/iavl/store.go \
    && fail "crates/cosmos/store-v2 is gitignored"
fi

echo "OK hasher packaging (iavl + store/v2 replaces, not gitignored)"
