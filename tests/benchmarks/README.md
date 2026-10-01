# BENCHMARKING

## Hasher IBC (v6.3 decision)

Hybrid (IBC SHA-256) vs full BLAKE3 + 08-wasm. Protocol:
[`networks/upgrades/v6.3/BENCH.md`](../../networks/upgrades/v6.3/BENCH.md).
JSON lands in `tests/benchmarks/hasher-ibc/`. Do not lock HASHER.md without it.

```sh
HASHER_VARIANT=H TERP_IMAGE_VERSION=v6.1.0-dev \
  cargo run -p ict-rs --example hasher_ibc_bench --features docker,testing,terp
```

`ICT_MOCK=1` is not a result.

## EXPERIMENTAL
- ffi design tradeoff: 