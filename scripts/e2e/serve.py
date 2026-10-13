#!/usr/bin/env python3
"""Serve tests/e2e and run one catalog id. Image tags come from the process environment."""

import json
import os
import subprocess
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PAGE = ROOT / "tests" / "e2e"
CATALOG = PAGE / "catalog.json"
RESULTS = PAGE / "results.json"


def wasmvm_rev() -> str:
    text = (ROOT / "x/wasm/wasmvm/libwasmvm/Cargo.toml").read_text()
    for line in text.splitlines():
        if "rev =" in line and '"' in line:
            return line.split('"')[1][:12]
    return ""


def terpd_version() -> str:
    repo = os.environ.get("TERP_IMAGE_REPO", "")
    version = os.environ.get("TERP_IMAGE_VERSION", "")
    if not repo or not version:
        return ""
    try:
        out = subprocess.run(
            ["docker", "run", "--rm", "--entrypoint", "terpd", f"{repo}:{version}", "version"],
            check=False,
            capture_output=True,
            text=True,
            timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return str(exc)
    line = (out.stdout or out.stderr).strip().splitlines()
    return line[-1] if line else ""


def load_catalog():
    return json.loads(CATALOG.read_text())


def error_line(text: str) -> str:
    skip = ("waiting for other jobs", "generated ", "proc-macro-error")
    lines = [ln.strip() for ln in text.splitlines() if ln.strip() and not any(s in ln for s in skip)]
    for ln in reversed(lines):
        low = ln.lower()
        if ln.startswith("Error:") or ln.startswith("ERROR:") or "panicked at" in ln or "section out of order" in low:
            return ln[:400]
    for ln in reversed(lines):
        low = ln.lower()
        if any(mark in low for mark in ("error", "failed", "panic", "timeout", "rejected")):
            return ln[:400]
    return ""


def log_tail(text: str, err: str) -> str:
    if err and err in text:
        at = text.rfind(err)
        return text[max(0, at - 200):at + 600]
    return text[-800:]


def run_id(entry_id: str) -> dict:
    entry = next(row for row in load_catalog() if row["id"] == entry_id)
    if not entry.get("argv"):
        return {"id": entry_id, "status": "skipped", "note": entry.get("note", "no argv")}
    env = os.environ.copy()
    missing = []
    for item in entry.get("env", []):
        if "=" in item:
            key, value = item.split("=", 1)
            env[key] = value
        elif not env.get(item):
            missing.append(item)
    if missing:
        return {"id": entry_id, "status": "skipped", "note": "set " + " ".join(missing)}
    started = time.time()
    proc = subprocess.run(
        entry["argv"],
        cwd=ROOT / entry["cwd"],
        env=env,
        text=True,
        capture_output=True,
    )
    seconds = round(time.time() - started, 2)
    blob = proc.stdout + proc.stderr
    status = "passed" if proc.returncode == 0 else "failed"
    err = error_line(blob) if status != "passed" else ""
    record = {
        "id": entry_id,
        "status": status,
        "seconds": seconds,
        "terpd": terpd_version(),
        "wasmvm": wasmvm_rev(),
        "image": f"{env.get('TERP_IMAGE_REPO', '')}:{env.get('TERP_IMAGE_VERSION', '')}".strip(":"),
        "tail": log_tail(blob, err),
    }
    if err:
        record["error"] = err
    prior = []
    if RESULTS.exists():
        prior = json.loads(RESULTS.read_text())
    prior = [row for row in prior if row.get("id") != entry_id]
    prior.append(record)
    RESULTS.write_text(json.dumps(prior, indent=2) + "\n")
    return record


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(PAGE), **kwargs)

    def do_POST(self):
        if self.path != "/run":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length) or b"{}")
        try:
            record = run_id(body["id"])
            code = 200
        except StopIteration:
            record = {"error": "unknown id"}
            code = 404
        raw = json.dumps(record).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


def main():
    PAGE.mkdir(parents=True, exist_ok=True)
    os.chdir(PAGE)
    server = ThreadingHTTPServer(("127.0.0.1", 8765), Handler)
    print("e2e catalog at http://127.0.0.1:8765")
    server.serve_forever()


if __name__ == "__main__":
    main()
