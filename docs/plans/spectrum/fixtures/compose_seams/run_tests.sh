#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
cargo test 2>&1
