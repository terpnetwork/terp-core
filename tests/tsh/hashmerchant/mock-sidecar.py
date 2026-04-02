#!/usr/bin/env python3
"""
Mock hashmerchant sidecar HTTP server.

Reads the latest Ethereum block from Anvil and serves the state root as a
vote extension payload.  Stdlib only — no pip dependencies.

Environment variables:
  ANVIL_RPC   - Anvil JSON-RPC URL (default: http://localhost:8545)
  PORT        - Listen port         (default: 8888)
"""

import json
import os
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.request import urlopen, Request

ANVIL_RPC = os.environ.get("ANVIL_RPC", "http://localhost:8545")
PORT = int(os.environ.get("PORT", "8888"))


def eth_get_block():
    """Fetch latest block from Anvil via eth_getBlockByNumber."""
    payload = json.dumps({
        "jsonrpc": "2.0",
        "method": "eth_getBlockByNumber",
        "params": ["latest", False],
        "id": 1,
    }).encode()
    req = Request(ANVIL_RPC, data=payload, headers={"Content-Type": "application/json"})
    with urlopen(req, timeout=3) as resp:
        data = json.loads(resp.read())
    return data.get("result", {})


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self._json_response(200, {"status": "ok"})
            return

        if self.path == "/vote-extension":
            try:
                block = eth_get_block()
                state_root = block.get("stateRoot", "")
                if not state_root or state_root == "0x":
                    self._json_response(503, {"error": "no state root from anvil"})
                    return
                # Strip 0x prefix for hex root
                root_hex = state_root[2:] if state_root.startswith("0x") else state_root
                height = int(block.get("number", "0x0"), 16)
                timestamp = int(block.get("timestamp", "0x0"), 16)

                body = {
                    "chain_uid": "ethereum-mainnet",
                    "algo": "keccak256",
                    "root": root_hex,
                    "foreign_height": height,
                    "foreign_block_time": timestamp,
                }
                self._json_response(200, body)
            except Exception as e:
                self._json_response(502, {"error": str(e)})
            return

        self._json_response(404, {"error": "not found"})

    def _json_response(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        # Keep logging concise
        sys.stderr.write(f"[sidecar] {fmt % args}\n")


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", PORT), Handler)
    print(f"[sidecar] listening on :{PORT}  anvil={ANVIL_RPC}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()
