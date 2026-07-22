# Epic — Stable local full multi-net e2e (P0 / P1 / P2)

| Field | Value |
|-------|--------|
| **Date** | 2026-07-22 |
| **Goal** | Path **stable, continuous, fully local multi-net every time** |
| **Bar** | BTC regtest → observe → deposit mint → SEAM swap → SettleSwap → Option D burn → ZEC lab pay; one dest seal |
| **Prior** | G1–G4, Option D, ict-rs `zakura` feature |

## Work split

| Tier | Owner | Scope |
|------|-------|--------|
| **P0** | IMPL-P0-STABLE (delegate) | Full observe path green; single seal; deposit mint default; evidence glue; wasm gate; Zakura preflight |
| **P1** | IMPL-P1-LAB-ZEC (delegate) | Real lab pay + open assert; `demo-corridor-full-local` one-button |
| **P2** | Parent session (parallel) | Docker/image pin docs; ports preflight; USER-GUIDE honesty |
| **META** | META-DELTA (delegate) | Delta vs end goal given prompts + goals |

## Definition of green (local)

```text
just prepare-corridor-ict-wasm-settle
Zakura up (or soft residual labeled)
just demo-corridor-ict-egress-d   # NOT mint-only only
receipts: settle + burn (cw) + zec; dest binding equal throughout
deposit ν continuous when obs present
re-run 2×
```

## Non-goals

Mainnet, mock_verify=false, Halo2 circuits, Option B/C as product.
