#!/usr/bin/env python3
"""
circuit-ffi-bench — Phase B dual-FFI harness skeleton
=====================================================

Design reference:
  docs/TERP-VOTE-SDK-VARIANT-AND-FFI-BENCH.md §5.4–§5.7
  docs/research/gpu-accel/STATUS-G4.md

Purpose
-------
Validate harness flags and emit JSONL/JSON result rows with the locked schema.
Does **not** require full Halo2/Groth16 circuits or live wasmvm when fixtures
are missing: in that case wall_* fields are null and status is "stub".

CRITICAL INVARIANTS (never violate)
-----------------------------------
1. wall ≠ gas
   - Wall clock (median_us / p95_us / wall_us) is performance only.
   - CosmWasm gas is NEVER derived as wall × const (GPU or CPU).
2. Gas only on Path W (--mode=wasmvm), from schedule resource units.
3. Path N (--mode=native) reports gas=null; no CosmWasm meter exists.
4. gas_source is always "schedule" when gas is present; never "wall".
5. GPU is optional acceleration. No device → backend_effective=gpu-fallback-cpu.
   Never claim real GPU benchmarks without hardware + plugged kernels.

Path plug-in points (later)
---------------------------
- Path N (vote-sdk CGO): see plug_path_n()
- Path W (wasmvm Path A): see plug_path_w()
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple

# ---------------------------------------------------------------------------
# Locked enums (§5.4 / §5.7)
# ---------------------------------------------------------------------------

MODES = ("native", "wasmvm")
ACCELS = ("cpu", "gpu")
CACHES = ("cold", "warm", "pin")
PAIRS = ("P-V-TOY", "P-V-SQUARE", "P-V-DEL", "P-WARM")
BACKENDS = ("cpu", "gpu", "gpu-fallback-cpu")

# Gas schedule mirrors packages/vm GasConfig::default halo2_proof_instance_verify_cost
# (docs/ZK-VERIFY-GAS.md). Units model only — NOT wall time.
GAS_PER_US = 1_000_000
SCHEDULE_BASE = 2_700 * GAS_PER_US  # ~2.7 ms fixed
SCHEDULE_PER_ITEM = 200 * GAS_PER_US  # ~200 µs / resource unit

# Default resource units when fixture sizes unknown (stub). Square Groth16 ≈ 3 units
# (1 + ceil(proof/1024) + ceil(instances/32)) — illustrative only for schema demos.
DEFAULT_STUB_UNITS = {
    "P-V-TOY": 16,
    "P-V-SQUARE": 3,
    "P-V-DEL": 48,
    "P-WARM": 16,
}

REPO_ROOT = Path(__file__).resolve().parents[2]

# Fixture hints (not required for skeleton). Relative to repo root.
FIXTURE_HINTS: Dict[str, List[str]] = {
    "P-V-TOY": [
        "crates/vote-sdk/ffi/zkp/testdata/toy_valid_proof.bin",
        "crates/vote-sdk/ffi/zkp/testdata",
        "crates/vote-sdk/tests/api/fixtures/toy_valid_proof.bin",
        "crates/cosmwasm/packages/zk/testdata/toy_vk.bin",
    ],
    "P-V-SQUARE": [
        "crates/cosmwasm/packages/zk/testdata/square_vk.bin",
        "crates/cosmwasm/packages/zk/testdata/square_proof.bin",
        "crates/cosmwasm/packages/zk/testdata/square_public.bin",
    ],
    "P-V-DEL": [
        "crates/vote-sdk/ffi/zkp/testdata",
        "crates/cosmwasm/packages/zk/testdata/delegation_vk.bin",
    ],
    "P-WARM": [
        "crates/vote-sdk/ffi/zkp/testdata/toy_valid_proof.bin",
        "crates/vote-sdk/ffi/zkp/testdata",
        "crates/cosmwasm/packages/zk/testdata",
    ],
}

# Optional external verify commands (shell). When set, each iter runs the command
# after fixture load. Gas is still NEVER taken from these timings.
# Example:
#   CIRCUIT_FFI_PATH_N_CMD='echo path-n-ok'
#   CIRCUIT_FFI_PATH_W_CMD='echo path-w-ok'
ENV_PATH_N_CMD = "CIRCUIT_FFI_PATH_N_CMD"
ENV_PATH_W_CMD = "CIRCUIT_FFI_PATH_W_CMD"


# ---------------------------------------------------------------------------
# Result schema
# ---------------------------------------------------------------------------


@dataclass
class BenchRow:
    """One matrix cell (§5.7.2 row keys + metrics).

    wall_us / median_us / p95_us are WALL CLOCK only.
    gas is CosmWasm schedule only on Path W; null on Path N.
    gas_source is always "schedule" (or null when gas is null) — never "wall".
    """

    pair_id: str
    mode: str  # native | wasmvm
    accel: str  # cpu | gpu (requested)
    cache: str  # cold | warm | pin
    backend_effective: str  # cpu | gpu | gpu-fallback-cpu
    # Wall metrics — null in stub mode (no real verify timed)
    wall_us: Optional[float]
    median_us: Optional[float]
    p95_us: Optional[float]
    n: int
    # Gas — Path W schedule only; NEVER wall×const
    gas: Optional[int]
    gas_source: Optional[str]  # "schedule" | null
    fixture: Optional[str]
    host: Dict[str, Any]
    gpu_device: Optional[str]
    status: str  # "stub" | "ok" | "error"
    note: str = ""
    batch: int = 1
    gas_units: Optional[int] = None  # schedule resource units (W only)
    schema_version: str = "circuit-ffi-bench/v1-skeleton"

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


# ---------------------------------------------------------------------------
# GPU detection (optional — never a consensus input)
# ---------------------------------------------------------------------------


def detect_gpu_device() -> Optional[str]:
    """Best-effort device string. TERP_GPU=1 is a detect *hint* only (§5.7.5).

    Skeleton honesty: we never claim active GPU kernels. Presence of a device
    string only means a probe found hardware; backend_effective still falls
    back unless a real Path N/W GPU plug-in reports success later.
    """
    # Explicit force-off
    if os.environ.get("TERP_GPU", "").strip() in ("0", "false", "off", "no"):
        return None

    # nvidia-smi
    if shutil.which("nvidia-smi"):
        try:
            out = subprocess.check_output(
                [
                    "nvidia-smi",
                    "--query-gpu=name",
                    "--format=csv,noheader",
                ],
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=3,
            ).strip()
            if out:
                return out.splitlines()[0].strip()
        except (subprocess.SubprocessError, OSError, FileNotFoundError):
            pass

    # macOS Metal probe (name only; no kernels claimed)
    if sys.platform == "darwin":
        try:
            out = subprocess.check_output(
                ["system_profiler", "SPDisplaysDataType"],
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=5,
            )
            for line in out.splitlines():
                if "Chipset Model:" in line or "Chipset Model" in line:
                    return line.split(":", 1)[-1].strip() + " (Metal probe)"
        except (subprocess.SubprocessError, OSError, FileNotFoundError):
            pass

    # Hint alone does not invent a device name
    if os.environ.get("TERP_GPU", "").strip() in ("1", "true", "on", "yes"):
        return "TERP_GPU=1 (hint only; no device probe succeeded)"

    return None


def resolve_backend_effective(
    accel: str,
    *,
    force_fallback: bool = False,
    gpu_device: Optional[str] = None,
    gpu_kernel_active: bool = False,
) -> Tuple[str, Optional[str]]:
    """Map --accel to backend_effective.

    Skeleton rule: GPU kernels are NOT wired. Even if a device is visible,
    backend_effective is gpu-fallback-cpu unless a future plug-in sets
    gpu_kernel_active=True after a successful GPU verify path.
    """
    if accel == "cpu":
        return "cpu", None
    # accel == gpu
    if force_fallback or not gpu_device or not gpu_kernel_active:
        # Document fallback row even without hardware (§5.7.1)
        return "gpu-fallback-cpu", gpu_device
    return "gpu", gpu_device


# ---------------------------------------------------------------------------
# Schedule gas (Path W only) — NEVER from wall
# ---------------------------------------------------------------------------


def schedule_gas(units: int) -> int:
    """halo2_proof_instance_verify_cost.total_cost(units).

    gas = base + per_item * units
    This is independent of CPU/GPU backend and of measured wall time.
    """
    return SCHEDULE_BASE + SCHEDULE_PER_ITEM * units


def path_w_gas(pair_id: str, units: Optional[int] = None) -> Tuple[int, int, str]:
    """Return (gas, units, gas_source='schedule')."""
    u = units if units is not None else DEFAULT_STUB_UNITS.get(pair_id, 16)
    return schedule_gas(u), u, "schedule"


# ---------------------------------------------------------------------------
# Fixture presence (optional for skeleton)
# ---------------------------------------------------------------------------


def find_fixture(pair_id: str) -> Optional[str]:
    for rel in FIXTURE_HINTS.get(pair_id, []):
        p = REPO_ROOT / rel
        if p.exists():
            try:
                return str(p.relative_to(REPO_ROOT))
            except ValueError:
                return str(p)
    return None


def host_info() -> Dict[str, Any]:
    return {
        "arch": platform.machine(),
        "system": platform.system(),
        "platform": platform.platform(),
        "python": platform.python_version(),
        "processor": platform.processor() or None,
    }


# ---------------------------------------------------------------------------
# Plug-in hooks — Path N (vote-sdk) and Path W (wasmvm)
# ---------------------------------------------------------------------------
#
# Phase B skeleton leaves these as stubs. Phase C+ should replace the bodies
# with real verify loops and fill wall metrics from timed iterations.
#
# Contract for a real plug-in:
#   def run(...) -> Tuple[List[float], Optional[bool]]:
#       returns (per-iter wall times in µs, accept_ok or None)
#   Must NOT return gas. Gas is always computed via schedule_gas on Path W.


def resolve_fixture_hint(pair_id: str, fixture: Optional[str]) -> Tuple[Optional[str], List[str]]:
    """Resolve an explicit fixture path or the first existing FIXTURE_HINTS entry.

    Returns (resolved_path_or_None, candidate_list). Never measures wall time.
    """
    candidates: List[str] = []
    if fixture:
        candidates.append(fixture)
    for rel in FIXTURE_HINTS.get(pair_id, []):
        candidates.append(rel)
    resolved: Optional[str] = None
    for rel in candidates:
        p = Path(rel)
        if not p.is_absolute():
            p = REPO_ROOT / rel
        if p.exists():
            resolved = str(p)
            break
    return resolved, candidates


def _collect_fixture_files(resolved: str, pair_id: str) -> List[Path]:
    """Expand a resolved fixture path into concrete files to load for wall timing."""
    p = Path(resolved)
    if not p.is_absolute():
        p = REPO_ROOT / resolved
    files: List[Path] = []
    if p.is_file():
        files.append(p)
        # Pair-sibling files for square / toy when we hit a single file first
        parent = p.parent
        if pair_id == "P-V-SQUARE":
            for name in ("square_vk.bin", "square_proof.bin", "square_public.bin"):
                cand = parent / name
                if cand.is_file() and cand not in files:
                    files.append(cand)
        if pair_id in ("P-V-TOY", "P-WARM"):
            for name in (
                "toy_valid_proof.bin",
                "toy_valid_input.bin",
                "toy_vk.bin",
            ):
                cand = parent / name
                if cand.is_file() and cand not in files:
                    files.append(cand)
        return files
    if p.is_dir():
        patterns = {
            "P-V-TOY": ("toy_valid_proof.bin", "toy_valid_input.bin", "toy_*.bin"),
            "P-V-SQUARE": ("square_vk.bin", "square_proof.bin", "square_public.bin"),
            "P-V-DEL": ("delegation*.bin", "share_reveal*.bin"),
            "P-WARM": ("toy_valid_proof.bin", "toy_valid_input.bin", "square_vk.bin"),
        }
        wanted = patterns.get(pair_id, ("*.bin",))
        for pat in wanted:
            for hit in sorted(p.glob(pat)):
                if hit.is_file() and hit not in files:
                    files.append(hit)
        if not files:
            files = sorted(x for x in p.iterdir() if x.is_file() and x.suffix == ".bin")[:6]
    return files


def _time_fixture_loads(
    files: Sequence[Path],
    *,
    iters: int,
    warm_first: bool,
    external_cmd: Optional[str],
) -> List[float]:
    """Return per-iter wall times in µs for fixture load (+ optional external cmd).

    This is **wall only**. Never used for CosmWasm gas.
    warm_first: load once before timing loop (WarmVerifierCaches / load_circuit analogue).
    """
    if not files:
        raise ValueError("no fixture files")
    if warm_first:
        for f in files:
            _ = f.read_bytes()
        if external_cmd:
            subprocess.run(
                external_cmd,
                shell=True,
                check=False,
                cwd=str(REPO_ROOT),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )

    times: List[float] = []
    n = max(1, iters)
    for _ in range(n):
        t0 = time.perf_counter()
        total = 0
        for f in files:
            data = f.read_bytes()
            total += len(data)
            # Touch payload so I/O is not fully optimized away
            if data:
                total ^= data[0]
        if external_cmd:
            subprocess.run(
                external_cmd,
                shell=True,
                check=False,
                cwd=str(REPO_ROOT),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        t1 = time.perf_counter()
        times.append((t1 - t0) * 1_000_000.0)
        _ = total  # keep work
    return times


def plug_path_n(
    pair_id: str,
    cache: str,
    backend_effective: str,
    *,
    iters: int,
    batch: int,
    fixture: Optional[str],
) -> Tuple[Optional[List[float]], str]:
    """Path N: vote-sdk native path (fixture-ready + optional CGO cmd).

    V6 plug:
      - Resolves toy/del fixtures under crates/vote-sdk/ffi/zkp/testdata
      - Times fixture load (and optional CIRCUIT_FFI_PATH_N_CMD) for wall µs
      - Never returns gas (Path N has no CosmWasm meter)
      - cache warm/pin: warm_first load (WarmVerifierCaches analogue)
      - cold: no prior load

    Full CGO: set CIRCUIT_FFI_PATH_N_CMD to a binary that calls VerifyToyProof etc.
    Returns (times_us or None if stub, note).
    """
    _ = (backend_effective, batch)
    resolved, candidates = resolve_fixture_hint(pair_id, fixture)
    if resolved is None:
        return None, (
            f"Path N stub: no fixture on disk for {pair_id}; "
            f"candidates={candidates[:4]}; add vote-sdk testdata or --fixture"
        )
    files = _collect_fixture_files(resolved, pair_id)
    if not files:
        return None, f"Path N stub: resolved {resolved} but no .bin files collected"
    warm_first = cache in ("warm", "pin")
    ext = os.environ.get(ENV_PATH_N_CMD, "").strip() or None
    times = _time_fixture_loads(
        files, iters=iters, warm_first=warm_first, external_cmd=ext
    )
    mode_note = "warm-first" if warm_first else "cold"
    ext_note = f"; external {ENV_PATH_N_CMD}" if ext else "; fixture-load wall only (set CIRCUIT_FFI_PATH_N_CMD for CGO Verify*)"
    return times, (
        f"Path N ok: {len(files)} file(s) from {resolved}; cache={mode_note}{ext_note}; "
        f"gas=null; backend_effective={backend_effective}"
    )


def plug_path_w(
    pair_id: str,
    cache: str,
    backend_effective: str,
    *,
    iters: int,
    batch: int,
    fixture: Optional[str],
) -> Tuple[Optional[List[float]], str]:
    """Path W: zk-wasmvm Path A (fixture-ready + optional host cmd).

    V6 plug:
      - Resolves square/toy fixtures under packages/zk/testdata
      - Times fixture load (cold / warm-first for load_circuit analogue / pin=warm+)
      - Optional CIRCUIT_FFI_PATH_W_CMD for real do_proof_instance_verify harness
      - Gas remains schedule-only via schedule_gas in the harness (not here)

    Returns (times_us or None if stub, note).
    """
    _ = (backend_effective, batch)
    resolved, candidates = resolve_fixture_hint(pair_id, fixture)
    cache_note = {
        "cold": "cold load each iter",
        "warm": "warm-first (load_circuit analogue)",
        "pin": "warm-first + pin label (pin_circuit analogue; not auto)",
    }.get(cache, cache)
    if resolved is None:
        return None, (
            f"Path W stub: no fixture for {pair_id} ({cache_note}); "
            f"candidates={candidates[:4]}; gas stays schedule-only"
        )
    files = _collect_fixture_files(resolved, pair_id)
    if not files:
        return None, f"Path W stub: resolved {resolved} but no .bin files; gas still schedule"
    warm_first = cache in ("warm", "pin")
    ext = os.environ.get(ENV_PATH_W_CMD, "").strip() or None
    times = _time_fixture_loads(
        files, iters=iters, warm_first=warm_first, external_cmd=ext
    )
    ext_note = (
        f"; external {ENV_PATH_W_CMD}"
        if ext
        else "; fixture-load wall only (set CIRCUIT_FFI_PATH_W_CMD for Path A verify)"
    )
    return times, (
        f"Path W ok: {len(files)} file(s) from {resolved}; cache={cache_note}{ext_note}; "
        f"gas=schedule in harness; backend_effective={backend_effective}"
    )


# ---------------------------------------------------------------------------
# Stats
# ---------------------------------------------------------------------------


def median(xs: Sequence[float]) -> float:
    s = sorted(xs)
    n = len(s)
    if n == 0:
        raise ValueError("empty")
    mid = n // 2
    if n % 2:
        return float(s[mid])
    return (s[mid - 1] + s[mid]) / 2.0


def percentile(xs: Sequence[float], p: float) -> float:
    """Nearest-rank p95-style percentile, p in [0,100]."""
    s = sorted(xs)
    n = len(s)
    if n == 0:
        raise ValueError("empty")
    if n == 1:
        return float(s[0])
    k = min(n - 1, max(0, int(round((p / 100.0) * (n - 1)))))
    return float(s[k])


# ---------------------------------------------------------------------------
# Cell runner
# ---------------------------------------------------------------------------


def run_cell(
    *,
    pair_id: str,
    mode: str,
    accel: str,
    cache: str,
    iters: int,
    batch: int,
    force_gpu_fallback: bool,
    allow_stub: bool,
) -> BenchRow:
    if mode not in MODES:
        raise ValueError(f"invalid mode={mode!r}; expected one of {MODES}")
    if accel not in ACCELS:
        raise ValueError(f"invalid accel={accel!r}; expected one of {ACCELS}")
    if cache not in CACHES:
        raise ValueError(f"invalid cache={cache!r}; expected one of {CACHES}")
    if pair_id not in PAIRS:
        raise ValueError(f"invalid pair={pair_id!r}; expected one of {PAIRS}")

    # Path N has no wasmvm pin; pin is treated as warm analogue (§5.7.2)
    note_bits: List[str] = []
    if mode == "native" and cache == "pin":
        note_bits.append(
            "Path N: cache=pin has no wasmvm pin; treated as warm (WarmVerifierCaches analogue)"
        )

    gpu_probe = detect_gpu_device() if accel == "gpu" else None
    # Skeleton: no GPU kernels wired → gpu_kernel_active stays False, so --accel=gpu
    # always yields backend_effective=gpu-fallback-cpu (honest: not a real GPU bench).
    # Future plug-ins may pass gpu_kernel_active=True only after a successful kernel path.
    backend_effective, gpu_device = resolve_backend_effective(
        accel,
        force_fallback=force_gpu_fallback,
        gpu_device=gpu_probe,
        gpu_kernel_active=False,
    )
    if accel == "gpu":
        note_bits.append(
            "GPU optional: skeleton has no kernels → backend_effective=gpu-fallback-cpu "
            "(not a real GPU benchmark)"
        )

    fixture = find_fixture(pair_id)

    if mode == "native":
        times, plug_note = plug_path_n(
            pair_id,
            cache if cache != "pin" else "warm",
            backend_effective,
            iters=iters,
            batch=batch,
            fixture=fixture,
        )
        # Path N: no CosmWasm gas
        gas: Optional[int] = None
        gas_source: Optional[str] = None
        gas_units: Optional[int] = None
    else:
        times, plug_note = plug_path_w(
            pair_id,
            cache,
            backend_effective,
            iters=iters,
            batch=batch,
            fixture=fixture,
        )
        # Path W: schedule gas only — identical for cpu / gpu / fallback on same inputs
        gas, gas_units, gas_source = path_w_gas(pair_id)
        note_bits.append(
            f"Path W gas={gas} from schedule (units={gas_units}); "
            "independent of wall and of backend_effective"
        )

    note_bits.append(plug_note)

    if times is None:
        if not allow_stub:
            raise RuntimeError(
                f"no real backend for {mode}/{pair_id} and --no-stub set "
                f"(fixtures={fixture!r})"
            )
        return BenchRow(
            pair_id=pair_id,
            mode=mode,
            accel=accel,
            cache=cache,
            backend_effective=backend_effective,
            wall_us=None,
            median_us=None,
            p95_us=None,
            n=0,
            gas=gas,
            gas_source=gas_source,
            fixture=fixture,
            host=host_info(),
            gpu_device=gpu_device if accel == "gpu" else None,
            status="stub",
            note="; ".join(note_bits),
            batch=batch,
            gas_units=gas_units,
        )

    # Real timings path (for future plug-ins)
    med = median(times)
    p95 = percentile(times, 95)
    return BenchRow(
        pair_id=pair_id,
        mode=mode,
        accel=accel,
        cache=cache,
        backend_effective=backend_effective,
        wall_us=med,  # alias of median for consumers expecting wall_us
        median_us=med,
        p95_us=p95,
        n=len(times),
        gas=gas,
        gas_source=gas_source,
        fixture=fixture,
        host=host_info(),
        gpu_device=gpu_device if accel == "gpu" else None,
        status="ok",
        note="; ".join(note_bits),
        batch=batch,
        gas_units=gas_units,
    )


def matrix_cells(
    modes: Sequence[str],
    accels: Sequence[str],
    caches: Sequence[str],
    pairs: Sequence[str],
) -> List[Tuple[str, str, str, str]]:
    cells = []
    for pair in pairs:
        for mode in modes:
            for accel in accels:
                for cache in caches:
                    cells.append((pair, mode, accel, cache))
    return cells


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

HELP_EPILOG = """
wall ≠ gas
  Wall metrics (wall_us / median_us / p95_us) are host wall-clock microseconds.
  CosmWasm gas is NEVER computed from wall time (including under GPU).
  gas is Path W (--mode=wasmvm) only, from GasConfig schedule × resource units.
  gas_source is always "schedule". Path N always has gas=null.

GPU
  --accel=gpu is optional. With no device or no kernels, backend_effective
  becomes gpu-fallback-cpu. Do not treat skeleton rows as real GPU benchmarks.

Examples
  %(prog)s --mode=native --accel=cpu --cache=cold --pair=P-V-TOY
  %(prog)s --mode=wasmvm --accel=gpu --cache=pin --pair=P-V-SQUARE --format=json
  %(prog)s --matrix --pair=P-V-TOY --format=jsonl
  %(prog)s --matrix-required   # CPU cold+warm/pin on N and W (g4 required cells)

See docs/TERP-VOTE-SDK-VARIANT-AND-FFI-BENCH.md §5.4–§5.7
"""


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="circuit_ffi_bench",
        description=(
            "Dual-FFI bench harness skeleton (Path N vote-sdk vs Path W wasmvm). "
            "Emits JSONL/JSON schema rows. Wall clock ≠ CosmWasm gas."
        ),
        epilog=HELP_EPILOG,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument(
        "--mode",
        choices=MODES,
        help="native=Path N (vote-sdk CGO); wasmvm=Path W (CosmWasm Path A)",
    )
    p.add_argument(
        "--accel",
        choices=ACCELS,
        default="cpu",
        help="cpu=force CPU; gpu=prefer GPU if device+kernel else gpu-fallback-cpu",
    )
    p.add_argument(
        "--cache",
        choices=CACHES,
        default="cold",
        help=(
            "cold|warm|pin — Path W: no load / load_circuit / pin_circuit; "
            "Path N: cold vs WarmVerifierCaches (pin≈warm). Pin ≠ GPU."
        ),
    )
    p.add_argument(
        "--pair",
        choices=PAIRS,
        action="append",
        dest="pairs",
        help="Pairable op id (repeatable). Default: P-V-TOY",
    )
    p.add_argument(
        "--iters",
        type=int,
        default=50,
        help="Timed iterations after setup (release target N≥50). Skeleton ignores.",
    )
    p.add_argument(
        "--batch",
        type=int,
        default=1,
        help="Optional batch size K (GPU ROI rows later). Skeleton records only.",
    )
    p.add_argument(
        "--format",
        choices=("jsonl", "json"),
        default="jsonl",
        help="jsonl = one object per line; json = array of rows",
    )
    p.add_argument(
        "--matrix",
        action="store_true",
        help="Expand over selected pairs × modes × accels × caches",
    )
    p.add_argument(
        "--matrix-required",
        action="store_true",
        help=(
            "Emit g4 required cells: CPU cold + warm + pin on both native and "
            "wasmvm for selected pairs (accel=cpu only)"
        ),
    )
    p.add_argument(
        "--modes",
        default="native,wasmvm",
        help="Comma list for --matrix (default native,wasmvm)",
    )
    p.add_argument(
        "--accels",
        default="cpu,gpu",
        help="Comma list for --matrix (default cpu,gpu)",
    )
    p.add_argument(
        "--caches",
        default="cold,warm,pin",
        help="Comma list for --matrix (default cold,warm,pin)",
    )
    p.add_argument(
        "--force-gpu-fallback",
        action="store_true",
        help="Force backend_effective=gpu-fallback-cpu when --accel=gpu",
    )
    p.add_argument(
        "--no-stub",
        action="store_true",
        help="Error if real Path N/W plug-in is not available (default: emit stub rows)",
    )
    p.add_argument(
        "--self-check",
        action="store_true",
        help="Validate schema invariants on emitted rows and exit non-zero on violation",
    )
    return p


def parse_csv_enum(raw: str, allowed: Sequence[str], name: str) -> List[str]:
    items = [x.strip() for x in raw.split(",") if x.strip()]
    for x in items:
        if x not in allowed:
            raise SystemExit(f"invalid {name} value {x!r}; allowed={list(allowed)}")
    return items


def self_check_row(row: BenchRow) -> List[str]:
    errs: List[str] = []
    if row.mode not in MODES:
        errs.append(f"bad mode {row.mode}")
    if row.accel not in ACCELS:
        errs.append(f"bad accel {row.accel}")
    if row.cache not in CACHES:
        errs.append(f"bad cache {row.cache}")
    if row.backend_effective not in BACKENDS:
        errs.append(f"bad backend_effective {row.backend_effective}")
    if row.accel == "cpu" and row.backend_effective != "cpu":
        errs.append("accel=cpu must have backend_effective=cpu")
    if row.accel == "gpu" and row.backend_effective not in ("gpu", "gpu-fallback-cpu"):
        errs.append("accel=gpu must be gpu or gpu-fallback-cpu")
    # Gas law
    if row.mode == "native":
        if row.gas is not None:
            errs.append("Path N must have gas=null")
        if row.gas_source is not None:
            errs.append("Path N must have gas_source=null")
    else:
        if row.gas is None:
            errs.append("Path W must have gas (schedule)")
        if row.gas_source != "schedule":
            errs.append('Path W gas_source must be "schedule" (never wall)')
        if row.gas is not None and row.gas_units is not None:
            expected = schedule_gas(row.gas_units)
            if row.gas != expected:
                errs.append(f"gas {row.gas} != schedule({row.gas_units})={expected}")
    # wall ≠ gas: if both present, they must not be equal by construction of gas_source
    if row.gas_source == "wall":
        errs.append("FORBIDDEN: gas_source=wall")
    if row.status == "stub":
        if row.wall_us is not None or row.median_us is not None or row.p95_us is not None:
            errs.append("stub rows must have null wall metrics")
    return errs


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    pairs = args.pairs or ["P-V-TOY"]
    allow_stub = not args.no_stub

    cells: List[Tuple[str, str, str, str]] = []
    if args.matrix_required:
        for pair in pairs:
            for mode in MODES:
                for cache in CACHES:
                    cells.append((pair, mode, "cpu", cache))
    elif args.matrix:
        modes = parse_csv_enum(args.modes, MODES, "modes")
        accels = parse_csv_enum(args.accels, ACCELS, "accels")
        caches = parse_csv_enum(args.caches, CACHES, "caches")
        cells = matrix_cells(modes, accels, caches, pairs)
    else:
        if not args.mode:
            parser.error("--mode is required unless --matrix or --matrix-required")
        for pair in pairs:
            cells.append((pair, args.mode, args.accel, args.cache))

    rows: List[BenchRow] = []
    for pair, mode, accel, cache in cells:
        row = run_cell(
            pair_id=pair,
            mode=mode,
            accel=accel,
            cache=cache,
            iters=args.iters,
            batch=args.batch,
            force_gpu_fallback=args.force_gpu_fallback,
            allow_stub=allow_stub,
        )
        rows.append(row)

    if args.self_check:
        all_errs: List[str] = []
        for i, row in enumerate(rows):
            for e in self_check_row(row):
                all_errs.append(f"row[{i}] {row.pair_id}/{row.mode}/{row.accel}/{row.cache}: {e}")
        if all_errs:
            for e in all_errs:
                print(e, file=sys.stderr)
            return 2

    dicts = [r.to_dict() for r in rows]
    if args.format == "json":
        json.dump(dicts, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
    else:
        for d in dicts:
            sys.stdout.write(json.dumps(d, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
