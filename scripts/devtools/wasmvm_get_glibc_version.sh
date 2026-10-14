#!/bin/bash
set -o errexit -o nounset -o pipefail
command -v shellcheck >/dev/null && shellcheck "$0"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [[ $# -eq 0 ]]; then
  files=("$ROOT"/x/wasm/wasmvm/internal/api/libwasmvm.*.so)
else
  files=("$@")
fi

for file in "${files[@]}"; do
  echo "Required glibc versions in $file:"
  objdump -T "$file" | grep GLIBC | sed 's/.*GLIBC_\([.0-9]*\).*/\1/g' | sort -V -u
done
