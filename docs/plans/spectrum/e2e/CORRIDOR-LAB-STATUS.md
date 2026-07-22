# Corridor status — lab floor vs ict_local_funded

**Date:** 2026-07-22 (raised bar: mainnet-funded-ready via local multi-net)  
**Owner track:** HARNESS-ICT-FUNDED (final-sprint-2026-07-22)  
**Honest labels:** `lab_simulated` ≠ `ict_local_funded` ≠ production/mainnet  
**Design freezes:** **D1–D7 FORMALLY ACCEPTED** — see [`../DESIGN-DECISIONS-CORRIDOR-ACCEPTED-2026-07-20.md`](../DESIGN-DECISIONS-CORRIDOR-ACCEPTED-2026-07-20.md)  
**Production readiness handoff:** [`../handoffs/HANDOFF-PRIVATE-BRIDGE-PRODUCTION-READINESS-2026-07-20.md`](../handoffs/HANDOFF-PRIVATE-BRIDGE-PRODUCTION-READINESS-2026-07-20.md)  
**Sprint STATUS:** [`../agents/final-sprint-2026-07-22/STATUS-HARNESS-OBSERVE.md`](../agents/final-sprint-2026-07-22/STATUS-HARNESS-OBSERVE.md)

---

## Profiles (do not collapse)

| Profile | Mint | Observe | One-command |
|---------|------|---------|-------------|
| **`lab_simulated`** (CI floor) | Mock / pure / mock_verify | Synthetic lab-observer OK | `just demo-corridor-lab` |
| **`ict_local_funded`** (sprint gate) | **Real local chain** `BridgeMintNote` via ict-rs + cw-orch Daemon | **BTC regtest** + `corridor-btc-reporter` (`bitcoind` backend) | `just demo-corridor-ict` |
| **production / mainnet** | Proof policy per deploy | Fulcrum / self-hosted index | ops (not CI) |

---

## What is green

| Surface | lab_simulated | ict_local_funded |
|---------|---------------|------------------|
| Pure CashApp→ZEC (I1–I6) | `fixtures/cashapp_zec_corridor && cargo test` | same pure spine after chain mint |
| Harness cashapp_zec | `cargo test -p zk-test-press --lib cashapp_zec --features 'interface,l0-seams'` | W0–W7 film in funded binary |
| L0 pure spine | `just demo-e2e-l0` | companion |
| L1 Mock BridgeMintNote | `just demo-e2e-l1` | Mock remains CI floor only |
| **L3 Daemon BridgeMintNote** | n/a | `just demo-corridor-ict` / `corridor_ict_funded` |
| hash-market corridor unit | `cargo test -p hash-market --lib corridor_deposits --features server` | **S6** amount/address gates |
| hash-market btc_index | Esplora multi + **bitcoind_rpc** unit | reporter `backend=bitcoind` vs regtest |
| Layer A host notify smoke | `corridor-lab-host.sh` | funded script starts host + open watch |
| Mint-after-observe film | `corridor-lab-mint-after-observe.sh` | called after chain mint |
| **One-command** | `just demo-corridor-lab` | **`just demo-corridor-ict`** |
| Settle + Option D | n/a | `just demo-corridor-ict-settle` / `demo-corridor-ict-egress-d` |
| Machine preflight | optional | `bash e2e/preflight-corridor-local.sh` · [MACHINE-PREREQS-LOCAL-E2E.md](./MACHINE-PREREQS-LOCAL-E2E.md) |
| Oline play preflight+e2e | `./preflight.sh --lab && ./e2e-test.sh` | regtest config `config/reporter.regtest.toml` |
| Multi-bin Dockerfile | server + corridor-btc-reporter | same image; host binary OK |
| Zakura local (D6) | offline dest | `zakura-local.sh` / ict-rs `feature=zakura`; live RPC for real lab pay |
| Terp image pin | — | `terpnetwork/terp-core:local-zk` (tag after build) |

### Notify + automation contract

```text
POST /corridor/watches                    → 201 (origin forced webapp)
GET  /corridor/watches                    → 200 { watches: [...] }
POST /corridor/observations               → 201 (addr must match open watch)
GET  /corridor/watches/:id                → 200 status=deposit_observed
GET  /corridor/watches/:id/events         → SSE event:corridor
PUT  /corridor/automation/:id             → 200 film phase (bridging|swapping|complete)
GET  /corridor/automation/:id             → 200 | 404  (UI polls post-deposit film)
```

Trust: observations + automation status are **coordination hints**. Mint authority remains **cw-headstash** / proofs — never the notify bus. Oracle is **bound_only** (never mints).

---

## Commands (copy-paste)

### Lab floor (S0) — one-command

```bash
cd crates/headstash
just demo-corridor-lab
```

### Funded profile (S1) — one-command

```bash
cd crates/headstash
just demo-corridor-ict
# requires: Docker, terpnetwork/terp-core:local-zk (or CORRIDOR_ICT_IMAGE_TAG),
#           artifacts/cw_headstash.wasm (auto-prepared), bitcoin/bitcoin image for regtest
#
# mock_verify on funded deploy: CORRIDOR_MOCK_VERIFY=true (default; labeled)
# chain mint only (dev residual): just demo-corridor-ict-mint-only
```

Evidence on success: log lines `IsBridgeMinted=true`, `deposit_observed via corridor-btc-reporter`, `OK ict_local_funded`.

### Mint-after-observe (deposit → private mint film → swap)

```bash
cd crates/headstash
just demo-corridor-mint-after-observe
# or:
bash docs/plans/spectrum/e2e/corridor-lab-mint-after-observe.sh

# After UI opened a watch and deposit was observed:
INTENT_ID=<intent> HASH_MARKET_URL=http://127.0.0.1:19090 \
  bash docs/plans/spectrum/e2e/corridor-lab-mint-after-observe.sh
```

UI production path polls:

```text
GET $HASH_MARKET_URL/corridor/automation/$INTENT_ID
```

Phases: `deposit_observed` → `bridging` → `swapping` → `complete`.

### Notify smoke only

```bash
cd crates/headstash && just demo-corridor-lab-smoke
bash docs/plans/spectrum/e2e/corridor-lab-host.sh
```

### Oline play (D4)

```bash
cd crates/o-line/plays/private-bridge-corridor
./preflight.sh --lab && ./e2e-test.sh          # lab floor
./preflight.sh --fulcrum                       # Esplora multi-tip OR Electrum TCP
./e2e-test.sh --index                          # soft multi-URL tip + watch list
# Funded regtest reporter config:
#   config/reporter.regtest.toml  (backend=bitcoind → local bitcoind)
# Compose BTC regtest:
#   docker compose -f docs/plans/spectrum/e2e/docker-compose.corridor-funded.yml up -d
```

### Indexer / money-gate unit tests

```bash
cd crates/terp-rs/tools/hash-market
cargo test -p hash-market --lib btc_index --features server
cargo test -p hash-market --lib corridor_deposits --features server
# S6: reject_addr_mismatch, reject_dust, reject_below_watch_min_amount, accept_at_or_above
```

### Sovereignty: lab vs funded vs oline prod

| Environment | Backend | Config |
|-------------|---------|--------|
| **Lab / CI** | Esplora multi-URL or synthetic observer | `reporter.esplora.toml`, `reporter.lab.toml` |
| **ict_local_funded** | **bitcoind regtest JSON-RPC** | `reporter.regtest.toml` + compose bitcoind |
| **Oline production** | **bitcoind → Fulcrum → electrum** | `reporter.fulcrum.toml` |
| **Avoid** | Public mainnet Esplora for live deposit watches | privacy + rate limits |

Topology:

```text
lab:     synthetic observer OR Esplora multi-failover → observations
funded:  bitcoind regtest → corridor-btc-reporter (bitcoind) → hash-market
         + ict-rs Terp → Daemon BridgeMintNote
prod:    bitcoind → Fulcrum → corridor-btc-reporter (electrum) → hash-market
```

### Pure / Mock companions

```bash
cd crates/headstash
just demo-e2e-l0
just demo-e2e-l1
just demo-corridor-lab-full
```

Default lab bind: **`http://127.0.0.1:19090`** (`HASH_MARKET_URL`).

---

## D1–D7 — **ACCEPTED** (locked for film + production wiring)

Source: [`../DESIGN-DECISIONS-CORRIDOR-ACCEPTED-2026-07-20.md`](../DESIGN-DECISIONS-CORRIDOR-ACCEPTED-2026-07-20.md)

| ID | Status | Lab / production wiring assumption |
|----|--------|-------------------------------------|
| **D1** | **ACCEPTED** | Egress = **SeamNoteOutV0 382B** only |
| **D2** | **ACCEPTED** | Domain B asset map id **≠** Domain C intent `domain_bind` — never merge |
| **D3** | **ACCEPTED (amended)** | Demo = private bridge mint **+ oracle-bound private swap** (swap required) |
| **D4** | **ACCEPTED** | Open reporter → observations; oline play skeleton landed |
| **D5** | **ACCEPTED** | Film default **`lab_simulated`**; UI lab banner only then |
| **D6** | **ACCEPTED (amended)** | Preauth `owner_binding`; **local Zakura harness** in `e2e/zakura/` (lightwalletd residual) |
| **D7** | **ACCEPTED** | Mint = **`cw-headstash` only**, `mock_verify` OK; oracle **bound_only** |

---

## UI production path (PrivateCorridor)

| Backend | Behavior |
|---------|----------|
| `lab_simulated` | Lab banner + local status film; optional lab publish observation |
| `production` / `lc_live` | No lab banner; on `deposit_observed` poll host automation; show bridging→swapping→complete |

Helper: `websites/dao-dao-ui/.../PrivateCorridor/automationClient.ts`  
Host driver: `corridor-lab-mint-after-observe.sh`

---

## Honest non-claims

| Claim | Status |
|-------|--------|
| Mainnet Cash App API / live BIP84 funding | **No** |
| Mainnet BTC/ZEC settlement | **No** |
| Notify / automation bus as mint authority | **No** |
| Second mint contract | **No** |
| Full Halo2 private swap in browser | **No** (host pure seams / later) |
| **Zakura local (D6)** | **Harness + regtest compose** — film green without node; live when RPC up (`e2e/ZAKURA-LOCAL.md`) |
| Multi-bin Dockerfile (server + reporter) | **Landed** — rebuild/push image still operator step |
| Fulcrum + bitcoind **running** in oline compose | **Residual** — config `reporter.fulcrum.toml` ready |
| Live funded testnet watch→observe | Soft-skipped in CI |
| Joint Anvil + terpd + LC dual-container | **Not claimed** |

---

## Layout

| Path | Role |
|------|------|
| `corridor-lab-host.sh` | Layer A: start hash-market lab + smoke + stop |
| `corridor-lab-smoke.sh` | Watch → observe → assert `deposit_observed` |
| `corridor-lab-mint-after-observe.sh` | Post-deposit pure mint+swap + automation API |
| `hash-market.lab.toml` / `.host.toml` | Lab configs |
| `lab-observer.sh` | Synthetic observations |
| `docker-compose.corridor-lab.yml` | Optional spectrum compose |
| `crates/o-line/plays/private-bridge-corridor/` | Oline play unit (D4) |
| `PrivateCorridor/automationClient.ts` | UI poll + production sequence |
| `just demo-corridor-lab` | One-command film |
| `just demo-corridor-mint-after-observe` | Mint-after-observe recipe |

---

## Residual (mainnet-only / packaging — not soft skip of funded mint)

1. **Mainnet keys, liquidity, legal** — not in CI; funded path proves workflow shape only.  
2. **Zakura lightwalletd / zcashd-compat wallet** — UA generation residual; mainnet ZEC out. Coord ZAKURA track for live regtest in funded stack.  
3. **oline Fulcrum packaging** — `reporter.fulcrum.toml` ready; compose Fulcrum image residual (P1).  
4. **P1 reorg revoke** — observations not auto-revoked on reorg; severity: operational. Address/amount gates are P0 and landed.  
5. **Electrum TLS** — residual for production Fulcrum TLS config.  
6. **Real Halo2 / non-mock_verify on funded local** — funded deploy defaults `mock_verify=true` (labeled D7). Set `CORRIDOR_MOCK_VERIFY=false` only with real proof path.  
7. **Browser → chain BridgeMintNote** — Daemon path is host binary; UI still polls automation API.

---

## Cross-links

- Acceptance: [`../DESIGN-DECISIONS-CORRIDOR-ACCEPTED-2026-07-20.md`](../DESIGN-DECISIONS-CORRIDOR-ACCEPTED-2026-07-20.md)
- Draft freezes: [`../DESIGN-DECISIONS-CORRIDOR-2026-07-20.md`](../DESIGN-DECISIONS-CORRIDOR-2026-07-20.md)
- Product SPEC: [`../DEMO-CASHAPP-ZEC-CORRIDOR.md`](../DEMO-CASHAPP-ZEC-CORRIDOR.md)
- Notify API: `crates/terp-rs/tools/hash-market/docs/corridor-deposit-notify.md`
- BTC reporter: `crates/terp-rs/tools/hash-market/docs/corridor-btc-reporter.md`
- Oline play: `crates/o-line/plays/private-bridge-corridor/README.md`
- Sprint STATUS: [`../agents/final-sprint-2026-07-22/STATUS-HARNESS-OBSERVE.md`](../agents/final-sprint-2026-07-22/STATUS-HARNESS-OBSERVE.md)
