#!/usr/bin/env python3
"""Split a CosmWasm-footer circuit blob into params + vk_body (cs+vk+footer)."""
import struct
import sys
from pathlib import Path

FOOTER = 80

def split(blob: bytes):
    if len(blob) < FOOTER:
        raise SystemExit(f"blob too short: {len(blob)}")
    foot = blob[-FOOTER:]
    prover, curve, k, i = foot[0], foot[1], foot[2], foot[3]
    param_len = struct.unpack_from("<I", foot, 4)[0]
    cs_len = struct.unpack_from("<I", foot, 8)[0]
    vk_len = struct.unpack_from("<I", foot, 12)[0]
    if param_len + cs_len + vk_len + FOOTER != len(blob):
        raise SystemExit(
            f"footer lengths {param_len}+{cs_len}+{vk_len}+{FOOTER} != {len(blob)}"
        )
    params = blob[:param_len]
    body = blob[param_len:]
    return params, body, prover, curve, k, i

def main():
    src, outdir = Path(sys.argv[1]), Path(sys.argv[2])
    outdir.mkdir(parents=True, exist_ok=True)
    params, body, prover, curve, k, i = split(src.read_bytes())
    (outdir / "params.bin").write_bytes(params)
    (outdir / "vk_body.bin").write_bytes(body)
    (outdir / "meta.env").write_text(
        f"CIRCUIT_PROVER={prover}\nCIRCUIT_CURVE={curve}\nCIRCUIT_K={k}\nCIRCUIT_I={i}\n"
    )
    print(f"split {src} param={len(params)} vk_body={len(body)} k={k} prover={prover} curve={curve}")

if __name__ == "__main__":
    main()
