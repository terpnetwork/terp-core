# Zakura local for Private Bridge (D6 ACCEPTED)

**Honest:** regtest / local node for **destination addresses** + RPC health — **not** mainnet ZEC send.  
**Freeze:** D6 — preauth ZEC dest + local Zakura.

## One command

```bash
# From monorepo root (Linux host with Docker):
cd crates/zakura && cargo build -p zakura --bin zakurad
export ZAKURAD_BIN="$(pwd)/target/debug/zakurad"
bash docs/plans/spectrum/e2e/zakura/zakura-local.sh up
bash docs/plans/spectrum/e2e/zakura/zakura-local.sh rpc-smoke
bash docs/plans/spectrum/e2e/zakura/zakura-local.sh dest
```

Just (from `crates/headstash`):

```bash
just demo-zakura-local-dest     # golden + dest + harness offline/golden tests (no docker)
just demo-zakura-local          # golden + dest + up/smoke when bin/docker ok + full harness
```

Golden vector (UI ↔ harness ↔ scripts):

```bash
bash docs/plans/spectrum/e2e/zakura/zakura-local.sh golden
# file: golden-dest-binding.json
# domain: terp-dest-binding-v0
# primary dest: tmJymvcUCn1ctbghvTJpXBwHiMEB8P6wxNV
# primary binding: 8b5cac11e39905d56126a0c538b84ff8daa379d8009d4e8b121112479607f09b
```

Harness (live tests skip if RPC down):

```bash
export ZAKURA_RPC=http://127.0.0.1:18232
cargo test -p zk-test-press --lib zakura_local --features 'interface,l0-seams' -- --nocapture
```

## Install channels (document only)

| Channel | Command / ref |
|---------|----------------|
| crates.io | `cargo install --locked zakura` then `zakurad start` |
| Docker Hub | `docker run … zakuracore/zakura:latest` (mainnet/testnet sync — **not** CI) |
| Installer | `curl -fsSL …/install-zakura.sh \| bash` |
| minisign | key `RWTZkHOmfhxdQf43RZJyOawUNvMSlbPH539O9Y2Sir/ZHTihqnSO1RZn` (VERIFY.md) |
| Vendored monorepo | `crates/zakura/` + `docker/docker-compose.zakura-regtest-e2e.yml` |

Prefer **regtest bind-mount** (`docker-compose.corridor-zakura.yml`) over mainnet sync for e2e.

## How UI gets a ZEC dest

1. Operator runs `zakura-local.sh dest` (or any wallet / lightwalletd UA).  
2. Paste **dest_display** into PrivateCorridor “ZEC dest” step.  
3. UI computes `owner_binding = SHA256("terp-dest-binding-v0|" ‖ dest_display)` (see `mock.ts`).  
4. Optional: set module/env `ZAKURA_RPC` for ops docs only — browser does not need full node for preauth digest.

```text
PrivateCorridor preauth
  ← dest_display (UA or transparent from Zakura / wallet)
  → dest_owner_binding (domain-separated digest)
  → DepositIntentV0 (D2: never merge with Domain B asset map id)
```

## RPC surface used by harness

| Method | Role |
|--------|------|
| `getblockchaininfo` | health / chain name |
| `validateaddress` | confirm dest on node network |
| *(no getnewaddress)* | Zakura core is not a wallet; dest = config `miner_address` or external UA |

Wallet RPC (`z_getnewaccount`, etc.) requires **zcashd-compat** residual (lightwalletd / zcashd sidecar).

## Compose join with corridor lab / **ict_local_funded** (HARNESS)

```text
# Port map (host network — node-corridor.toml)
#   RPC     http://127.0.0.1:18232   ← ZAKURA_RPC / NEXT_PUBLIC_ZAKURA_RPC
#   P2P     127.0.0.1:18233
#   metrics 127.0.0.1:19901

# Option A — host Layer A (preferred for funded stack attach):
#   HASH_MARKET_URL=http://127.0.0.1:19090   (or HARNESS hash-market)
#   ZAKURA_RPC=http://127.0.0.1:18232
#   bash docs/plans/spectrum/e2e/zakura/zakura-local.sh up
#   bash docs/plans/spectrum/e2e/zakura/zakura-local.sh dest
#   → export dest_display into corridor intent / UI paste

# Option B — full Zakura dual-stack e2e (heavy):
#   crates/zakura/docker/zakura-regtest-e2e/run.sh

# Option C — oline private-bridge-corridor play inventory:
#   Zakura is sidecar env only (not ict-rs ChainSpec)
#   ZAKURA_RPC=http://127.0.0.1:18232
#   optional wait: curl -sf -X POST $ZAKURA_RPC/ -d '{"jsonrpc":"2.0","id":1,"method":"getblockchaininfo","params":[]}'
```

### HARNESS attach checklist (`ict_local_funded`)

| Step | Action |
|------|--------|
| 1 | Spin Terp + hash-market via ict-rs / corridor play (HARNESS owns) |
| 2 | Start Zakura regtest: `zakura-local.sh up` (needs Linux `ZAKURAD_BIN` + Docker) |
| 3 | Assert dest: `zakura-local.sh golden && zakura-local.sh dest` |
| 4 | Seal intent with `owner_binding` from step 3 (or harness `primary_golden_dest()`) |
| 5 | On receipt / open: assert `dest_owner_binding` == golden / sealed binding |
| 6 | Offline CI floor: golden + `primary_golden_dest()` without Docker |

Network alias `zakura` is only meaningful if both services share a user-defined bridge network.  
Regtest compose uses **host networking** (Zakura requirement for localhost peers), so alias is documentation-only for host mode.

## ict-rs

Zakura is a **sidecar**, not an ict-rs `ChainSpec` chain. No Anvil/Terp dual path change.  
Funded profile: HARNESS waits on `ZAKURA_RPC` HTTP health (or uses golden offline dest) before dest-binding assertions — do not invent a Cosmos `ChainSpec`.

## Residual

| Item | Notes |
|------|--------|
| lightwalletd / mobile wallet UA generation | Optional compose `docker-compose.lwd.yml` under zakura; not wired here |
| zcashd-compat wallet RPC | Separate install path for exchanges |
| macOS Docker | Needs Linux `zakurad` binary (regtest-e2e Dockerfile artifact) |
| Mainnet ZEC send | Out of scope (D6 lab) |
