# Corridor lab e2e (local containers / host)

**Honest scope:** lab notify plane + pure/Mock suite — **not** mainnet Cash App / ZEC.

Status snapshot: [`CORRIDOR-LAB-STATUS.md`](./CORRIDOR-LAB-STATUS.md)

## Team owner

| Track | Report / agent |
|-------|----------------|
| **HARNESS** | `agents/ROUND3-HARNESS-E2E.md`, `agents/ROUND2-HARNESS.md`, `agents/DEMO-CORRIDOR-E2E.md` |
| Design freezes | `../DESIGN-DECISIONS-CORRIDOR-2026-07-20.md` **D1–D7** |

## Design freezes

**D1–D7 FORMALLY ACCEPTED** — `../DESIGN-DECISIONS-CORRIDOR-ACCEPTED-2026-07-20.md`

## One command (preferred)

From `crates/headstash` (or `docs/plans/spectrum`):

```bash
cd crates/headstash && just demo-corridor-lab
# or:
cd docs/plans/spectrum && just demo-corridor-lab
```

Runs:

1. pure `cashapp_zec_corridor` (I1–I6)
2. `zk-test-press` `cashapp_zec` harness (`CorridorAssetBackend::Simulated`)
3. host hash-market lab server + `corridor-lab-smoke.sh` (watch → observe → `deposit_observed`)

Notify-only / mint-after-observe:

```bash
just demo-corridor-lab-smoke
just demo-corridor-mint-after-observe
# INTENT_ID=... bash docs/plans/spectrum/e2e/corridor-lab-mint-after-observe.sh
```

Oline play (D4 skeleton):

```bash
bash crates/o-line/plays/private-bridge-corridor/e2e-test.sh
```

Zakura local dest (D6; optional — does not block demo-corridor-lab):

```bash
just demo-zakura-local-dest
# live RPC: see docs/plans/spectrum/e2e/ZAKURA-LOCAL.md
```

Companion pure L0 / L1:

```bash
just demo-e2e-l0   # bridge / dex / SEAM / compose pure
just demo-e2e-l1   # cw-orch Mock BridgeMintNote (cw-headstash only)
```

## Layer A — host (no Docker) — working path

```bash
# L0 pure + cashapp corridor
cd crates/headstash && just demo-e2e-l0
cargo test -p zk-test-press --lib cashapp_zec --features 'interface,l0-seams'

# hash-market notify plane (auto start + smoke + stop)
bash docs/plans/spectrum/e2e/corridor-lab-host.sh

# or manual two-terminal:
cd crates/terp-rs/tools/hash-market
# use host lab config (writable data_dir); or let corridor-lab-host.sh generate one
cargo run --release --bin hash-market-server --features server -- \
  -c ../../../../docs/plans/spectrum/e2e/hash-market.lab.host.toml
# other terminal (default URL matches host lab bind :19090):
export HASH_MARKET_URL=http://127.0.0.1:19090
bash docs/plans/spectrum/e2e/corridor-lab-smoke.sh
```

Optional BTC light index (staging / oline residual — not required for lab film):

```bash
cd crates/terp-rs/tools/hash-market
cargo run --release --bin corridor-btc-reporter --features server -- -c reporter.example.toml
# set backend=esplora + mempool testnet API for staging
```

## Layer B — docker compose (optional)

Docker image build is multi-minute (Rust release in Dockerfile). **Prefer Layer A** unless you need container packaging practice.

```bash
# Build context must be terp-rs monorepo root (Dockerfile COPY paths)
cd crates/terp-rs
docker build -t terp/hash-market:corridor-lab -f tools/hash-market/Dockerfile \
  --build-arg FEATURES=server .

# From repo root:
docker compose -f docs/plans/spectrum/e2e/docker-compose.corridor-lab.yml up --build
```

Smoke:

```bash
export HASH_MARKET_URL=http://127.0.0.1:19090
bash docs/plans/spectrum/e2e/corridor-lab-smoke.sh
```

`lab-observer` posts synthetic observations for open watches (no bitcoind).

## Layer C — production oline (later residual)

```text
bitcoind → Fulcrum → corridor-btc-reporter → hash-market-server
```

See `crates/terp-rs/tools/hash-market/docs/corridor-btc-reporter.md`.

## Design decisions for the film

Assume **D1–D7** in `DESIGN-DECISIONS-CORRIDOR-2026-07-20.md` unless amended in writing.

| ID | Freeze (summary) |
|----|------------------|
| D1 | SeamNoteOutV0 382B only egress |
| D2 | Domain B asset map ≠ Domain C intent `domain_bind` |
| D3 | Demo = bridge mint only (not airdrop claim) |
| D4 | Open reporter → `/corridor/observations`; UI re-verifies |
| D5 | Container/host film = `lab_simulated` |
| D6 | ZEC dest = preauth diversifier / `owner_binding` digest |
| D7 | Mint = `cw-headstash` only; `mock_verify=true` for container; oracle bound_only |

## Non-claims

- No mainnet Cash App API / BIP84 live funding
- No mainnet BTC / ZEC transfer
- Notify bus is **not** mint authority
- Lab observer txids are synthetic
