# Machine prerequisites — stable local multi-net e2e

| Field | Value |
|-------|--------|
| **Profile** | `ict_local_funded` (+ settle / Option D) |
| **Not** | Mainnet money, production LC proofs |

## Required tools

| Tool | Why |
|------|-----|
| Docker + dockerd | ict-rs Terp, BTC regtest compose, optional Zakura |
| `cargo` (nightly OK for monorepo) | wasm guests, hash-market, corridor_ict_funded |
| `curl`, `python3` | health / wasm surface checks |
| `wasm-opt` (binaryen **≥120**) | bulk-memory lowering for guest wasm |

```bash
# macOS example
brew install binaryen
wasm-opt --version   # ≥ 120
```

## Pinned images / binaries

| Component | Pin / env | Notes |
|-----------|-----------|--------|
| Terp chain | `terpnetwork/terp-core:local-zk` | Override `CORRIDOR_TERP_IMAGE` / ict image env if your build differs |
| Headstash wasm | `crates/headstash/artifacts/cw_headstash.wasm` | `just prepare-corridor-ict-wasm` / settle variant |
| Private dex wasm | `…/cw_private_dex.wasm` | `CORRIDOR_PREPARE_PRIVATE_DEX=1` |
| Zakura | host `ZAKURAD_BIN` (Linux binary for Docker Desktop) | `ict-rs` `feature=zakura` or `zakura-local.sh up` |

Build Terp local-zk once and **tag** so pulls do not flail:

```bash
# after building terpd image in your usual path:
docker tag <built-image> terpnetwork/terp-core:local-zk
```

## Host ports

| Port | Service |
|------|---------|
| **19090** | hash-market-server (corridor HTTP) |
| **18232** | Zakura JSON-RPC |
| **18443** | bitcoind regtest RPC (compose) |
| **26657** | typical Cosmos RPC (ict-assigned may differ) |

Preflight:

```bash
bash docs/plans/spectrum/e2e/preflight-corridor-local.sh
CORRIDOR_CHAIN_SETTLE=1 CORRIDOR_ZEC_EGRESS_D=1 bash docs/plans/spectrum/e2e/preflight-corridor-local.sh
```

## One-shot commands (fidelity ladder)

| Command | What it proves |
|---------|----------------|
| `just demo-corridor-lab` | Lab floor only |
| `just demo-corridor-ict` | Observe + BridgeMintNote |
| `just demo-corridor-ict-settle` | + SettleSwap |
| `just demo-corridor-ict-egress-d` | + Option D burn + lab ZEC pay |
| `just demo-corridor-full-local` | When landed: prepare + zakura + full path |

## Honesty labels

- Default **`mock_verify=true`** on local funded = **lab proof policy**, not production soundness.
- **`lab_inventory_pay_simulated`** = no live Zcash wallet send yet.
- Local success **≠** mainnet Cash App → ZEC settlement.
