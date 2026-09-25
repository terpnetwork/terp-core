# circuit-ffi-bench (Phase B + V6 fixture-ready plugs)

Dual-path FFI benchmark harness for **Path N** (vote-sdk native / CGO) vs **Path W** (zk-wasmvm / CosmWasm Path A).

**Spec:** [`docs/TERP-VOTE-SDK-VARIANT-AND-FFI-BENCH.md`](../../docs/TERP-VOTE-SDK-VARIANT-AND-FFI-BENCH.md) §5.4–§5.7  
**Matrix design:** [`docs/research/gpu-accel/STATUS-G4.md`](../../docs/research/gpu-accel/STATUS-G4.md)  
**V6 STATUS:** [`docs/research/vote-terp-orch/STATUS-V6.md`](../../docs/research/vote-terp-orch/STATUS-V6.md)

### V6 plugs (2026-07-26)

When fixtures exist on disk, rows are `status=ok` with real **wall µs** (fixture load; optional external verify cmd). Path W still emits **schedule gas only**.

| Env | Role |
|-----|------|
| `CIRCUIT_FFI_PATH_N_CMD` | Optional shell cmd each Path N iter (CGO Verify*) |
| `CIRCUIT_FFI_PATH_W_CMD` | Optional shell cmd each Path W iter (Path A verify) |

## Invariants (non-negotiable)

| Rule | Meaning |
|------|---------|
| **wall ≠ gas** | Never set CosmWasm gas from wall µs (`gas = wall × const` forbidden, including GPU). |
| **Gas only on Path W** | `--mode=wasmvm` emits `gas` + `gas_source="schedule"`. Path N has `gas=null`. |
| **Schedule identity** | Gas = `halo2_proof_instance_verify_cost` (base + per_item × units); same for cpu / gpu / gpu-fallback-cpu on equal inputs. |
| **GPU optional** | `--accel=gpu` without device/kernels → `backend_effective=gpu-fallback-cpu`. No real GPU claim without hardware + plugged kernels. |
| **Default builds** | This tool is standalone Python under `tools/`; it does not change crate feature defaults. |

## Flags (locked)

```text
--mode=native|wasmvm
--accel=cpu|gpu
--cache=cold|warm|pin
--pair=P-V-TOY|P-V-SQUARE|P-V-DEL|P-WARM   # repeatable
--iters=N                                  # release target ≥50 (recorded; stub ignores)
--batch=K                                  # optional; future GPU ROI
--format=jsonl|json
--matrix / --matrix-required
--force-gpu-fallback
--self-check
```

## Sample invocations

```bash
# Single stub cell (Path N CPU cold)
python3 tools/circuit-ffi-bench/circuit_ffi_bench.py \
  --mode=native --accel=cpu --cache=cold --pair=P-V-TOY

# Path W with GPU request → skeleton emits gpu-fallback-cpu + schedule gas
python3 tools/circuit-ffi-bench/circuit_ffi_bench.py \
  --mode=wasmvm --accel=gpu --cache=pin --pair=P-V-SQUARE --format=json

# g4 required matrix: CPU cold/warm/pin × native/wasmvm
python3 tools/circuit-ffi-bench/circuit_ffi_bench.py \
  --matrix-required --pair=P-V-TOY --format=jsonl --self-check

# Full mode×accel×cache expansion for one pair
python3 tools/circuit-ffi-bench/circuit_ffi_bench.py \
  --matrix --pair=P-V-TOY --format=jsonl
```

### Example stub row (schema)

```json
{
  "pair_id": "P-V-TOY",
  "mode": "wasmvm",
  "accel": "gpu",
  "cache": "pin",
  "backend_effective": "gpu-fallback-cpu",
  "wall_us": null,
  "median_us": null,
  "p95_us": null,
  "n": 0,
  "gas": 5900000000,
  "gas_source": "schedule",
  "gas_units": 16,
  "fixture": null,
  "host": { "arch": "...", "system": "..." },
  "gpu_device": null,
  "status": "stub",
  "schema_version": "circuit-ffi-bench/v1-skeleton"
}
```

`wall_*` null means **stub / not measured** — not zero latency. `gas` on Path W is **schedule**, not wall.

## How to plug Path N (vote-sdk)

Implement the body of `plug_path_n()` in `circuit_ffi_bench.py` (or replace with a subprocess driver):

1. **Build:** `crates/vote-sdk` with `-tags halo2` (optional `-tags gpu` for Façade B hooks; default OFF).
2. **Entry:** `ffi/zkp/halo2` `Verify*` for the pair (`P-V-TOY`, `P-V-DEL`, …).
3. **Cache:** `cold` = no prior warm; `warm`/`pin` = call `WarmVerifierCaches()` first (`pin` has no wasmvm meaning on N — treat as warm).
4. **Accel:** respect pre-resolved `backend_effective`; if GPU plug fails, harness already labels `gpu-fallback-cpu`.
5. **Measure:** discard setup iters; collect ≥50 wall samples (µs); return list of floats. **Do not return gas.**
6. **Fixtures:** e.g. `crates/vote-sdk/ffi/zkp/testdata/toy_valid_*.bin`.

Reference patterns: `vote-sdk/ffi/zkp/halo2/*_test.go`, G3 `GPU-FEATURE-HOOKS.md`.

## How to plug Path W (wasmvm)

Implement `plug_path_w()`:

1. **Store** circuit blob if needed; then per `--cache`:
   - `cold` — avoid prior `load_circuit` / pin (or new process)
   - `warm` — `load_circuit` only (LRU/fs; **not** pin)
   - `pin` — explicit `pin_circuit`
2. **Verify loop:** libwasmvm / Rust mirror of `do_proof_instance_verify` (G2 `VerifierBackend`).
3. **Gas:** already emitted by the harness via `schedule_gas(units)` matching `GasConfig::halo2_proof_instance_verify_cost`. When wiring live VM, **read scheduled gas from the meter**, do not invent from wall. GPU must not change gas for same proof/PI units.
4. **Fixtures:** e.g. `packages/zk/testdata/square_{vk,proof,public}.bin` for `P-V-SQUARE`.

Reference patterns: `packages/zk/src/bin/verify_gas_calibrate.rs`, `packages/vm/benches/zk_circuit.rs`, `DESIGN-G1-verifier-backend.md`.

## Exclusions (do not dual-FFI)

Votetree Poseidon, RedPallas, blake digests, store-only W costs — see plan §5.7.4.

## Status honesty

Skeleton rows have `status="stub"` and null wall metrics. They **do not** claim measured verify performance or real GPU acceleration. Use `--self-check` to assert gas-law invariants in CI without needing circuits.
