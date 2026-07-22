# Zakura local status (D6 ACCEPTED — paste-first + live regtest path)

**Date:** 2026-07-22  
**Track:** ZAKURA-DEST (final sprint raised bar)  
**Honest:** regtest dest + RPC health + shared binding golden — **not** mainnet ZEC  

## Green without live node (CI floor)

```bash
cd crates/headstash
just demo-zakura-local-dest
# golden-dest-binding.json parity + dest print + harness offline/golden tests
```

`just demo-corridor-lab` remains green with synthetic dest binding.  
Zakura live node is **required for funded-profile fidelity (S5)**, optional for lab film.

## Green with Zakura (when RPC up)

```bash
# Linux + Docker + host-built zakurad:
cd crates/zakura && cargo build -p zakura --bin zakurad
export ZAKURAD_BIN="$(pwd)/target/debug/zakurad"
bash docs/plans/spectrum/e2e/zakura/zakura-local.sh up
bash docs/plans/spectrum/e2e/zakura/zakura-local.sh rpc-smoke

cd crates/headstash
cargo test -p zk-test-press --lib zakura_local --features 'interface,l0-seams' -- --nocapture
# offline + golden always pass; live tests skip cleanly if RPC down
```

Just:

```bash
cd crates/headstash
just demo-zakura-local-dest   # golden + dest + harness (no docker)
just demo-zakura-local        # + up/smoke when bin/docker available
```

## Golden vector (`terp-dest-binding-v0`)

| Field | Value |
|-------|--------|
| Path | `docs/plans/spectrum/e2e/zakura/golden-dest-binding.json` |
| Domain | `terp-dest-binding-v0` |
| Preimage | `domain \| utf8_trim(dest_display)` → SHA-256 |
| Primary dest | `tmJymvcUCn1ctbghvTJpXBwHiMEB8P6wxNV` |
| Primary binding | `8b5cac11e39905d56126a0c538b84ff8daa379d8009d4e8b121112479607f09b` |
| UI | `zakuraDest.ts` (`DEST_BINDING_DOMAIN`, `GOLDEN_OWNER_BINDING_HEX`, `destOwnerBindingHex`) |
| Harness | `zakura_local.rs` (`owner_binding_from_dest_display`, `primary_golden_dest`) |

```text
zakura-local.sh dest  →  dest_display + owner_binding
PrivateCorridor paste dest_display  →  same SHA256(terp-dest-binding-v0|…)
funded e2e receipt  →  assert dest_owner_binding match
```

## ict-rs feature (`zakura`)

Local spawn is also wired **in-crate** (hardcoded corridor defaults):

```toml
ict-rs = { path = "...", features = ["zakura"] }  # implies docker
```

```rust
use ict_rs::chain::zakura::{spawn_zakura_local, ZakuraNodeConfig};
// ZAKURAD_BIN=/path/to/linux/zakurad
let node = spawn_zakura_local(runtime, ZakuraNodeConfig::from_env()).await?;
// RPC http://127.0.0.1:18232 — same seal/domain as this document
```

See `crates/ict-rs/ict-rs/src/chain/zakura.rs` and `ict-rs` README § Zakura local.

## Funded stack ports (for HARNESS)

| Service | Host | Env |
|---------|------|-----|
| Zakura JSON-RPC | `http://127.0.0.1:18232` | `ZAKURA_RPC`, `NEXT_PUBLIC_ZAKURA_RPC` |
| Zakura P2P | `127.0.0.1:18233` | (compose only) |
| Zakura metrics | `127.0.0.1:19901` | (ops) |
| Compose | `e2e/zakura/docker-compose.corridor-zakura.yml` | `ZAKURAD_BIN` required |
| ict-rs | `feature = "zakura"` | `ZAKURAD_BIN` + Docker |

Host networking — no Docker bridge alias for peers. Start after or beside ict Terp; dest is independent of Cosmos chain.

## Layout

| Path | Role |
|------|------|
| `e2e/zakura/README.md` | runbook + install channels + HARNESS attach |
| `e2e/zakura/golden-dest-binding.json` | shared binding golden |
| `e2e/zakura/zakura-local.sh` | status/up/down/dest/rpc-smoke/**golden** |
| `e2e/zakura/docker-compose.corridor-zakura.yml` | single regtest node |
| `e2e/zakura/node-corridor.toml` | RPC :18232, miner dest |
| `test-press/.../zakura_local.rs` | harness helper + golden + live tests |
| `PrivateCorridor/zakuraDest.ts` | paste soft-validate + demo dest helpers |

## Residual

| Item | Notes |
|------|--------|
| lightwalletd | `crates/zakura/docker/docker-compose.lwd.yml` — not wired to corridor |
| zcashd-compat wallet | needed for `z_getnew*` address generation |
| macOS Docker | Linux `zakurad` artifact required |
| ict-rs ChainSpec | Zakura is **sidecar** only |
| Browser CORS | paste-first is primary; RPC button optional |

Production readiness: `docs/plans/spectrum/handoffs/HANDOFF-PRIVATE-BRIDGE-PRODUCTION-READINESS-2026-07-20.md`
