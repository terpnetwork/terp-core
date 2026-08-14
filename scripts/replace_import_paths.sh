#!/bin/bash
# Bump this repo's Go module major import path (vN -> vM).
# Walks the chain workspace only. crates/ is never rewritten.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <next_major>" >&2
  exit 1
fi

NEXT_MAJOR_VERSION="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

import_path_to_replace="$(go list -m)"
version_to_replace="$(echo "$import_path_to_replace" | sed -n 's/.*v\([0-9][0-9]*\).*/\1/p')"

if [[ -z "$version_to_replace" ]]; then
  echo "could not parse current major from: $import_path_to_replace" >&2
  exit 1
fi

if [[ "$version_to_replace" == "$NEXT_MAJOR_VERSION" ]]; then
  echo "already on v${NEXT_MAJOR_VERSION} ($import_path_to_replace)"
  exit 0
fi

echo "Current import paths are v${version_to_replace}, replacing with v${NEXT_MAJOR_VERSION}"

# GNU sed accepts -i; BSD/Darwin sed requires a backup suffix.
if sed --version >/dev/null 2>&1; then
  sed_inplace() { sed -i "$1" "$2"; }
else
  sed_inplace() { sed -i "" "$1" "$2"; }
fi

replace_paths() {
  local file="$1"
  sed_inplace "s|github.com/terpnetwork/terp-core/v${version_to_replace}|github.com/terpnetwork/terp-core/v${NEXT_MAJOR_VERSION}|g" "$file"
}

# Prune: crates (requested), plus trees that are not the chain module.
PRUNE=(
  -path ./crates -o
  -path ./vendor -o
  -path ./.git -o
  -path ./build -o
  -path ./artifacts -o
  -path ./.worktrees -o
  -path ./optimizer -o
  -path ./websites -o
  -path ./notes
)

echo "Replacing import paths in workspace files (omitting crates/)"

files=()
while IFS= read -r line; do
  files+=("$line")
done < <(find ./ \( "${PRUNE[@]}" \) -prune -o -type f \
  \( -name "*.go" -o -name "*.proto" -o -name "go.mod" -o -name "go.work" \
     -o -name "*.yml" -o -name "*.yaml" -o -name "*.json" -o -name "*.toml" \
     -o -name "*.sh" -o -name "*.mk" -o -name "Makefile" -o -name "Dockerfile*" \
     -o -name "buf.gen.yaml" -o -name "buf.work.yaml" \) -print)

echo "Updating ${#files[@]} files"

for file in "${files[@]}"; do
  if [[ -f "$file" ]]; then
    replace_paths "$file"
  fi
done

echo "done. leftover v${version_to_replace} (excluding crates/):"
find ./ \( "${PRUNE[@]}" \) -prune -o -type f \
  \( -name "*.go" -o -name "go.mod" -o -name "*.proto" \) -print0 \
  | xargs -0 grep -l "github.com/terpnetwork/terp-core/v${version_to_replace}" 2>/dev/null \
  | head -20 || true
