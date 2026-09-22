# Headers And Ingress

How headers, finality signals, and related evidence enter a consumer chain so light clients can advance.

This chapter is **technical**.

## Ingress roles

| Role | Responsibility |
|------|----------------|
| **Source node** | Zcash / Crosslink full node (e.g. zebrad family) exporting headers, finality, or RPC |
| **Relayer / operator** | Formats and submits `UpdateClient` (and packet/proof messages) to the consumer chain |
| **Wasm light client** | Validates updates against current client state; advances consensus state |
| **Application** | Reads verified heights/roots; may gate contract logic or IBC handlers |

## Typical flow

```
Zcash / Crosslink tip
        │
        ▼
  Header / finality export (RPC, indexer, custom feeder)
        │
        ▼
  Relayer builds client update message
        │
        ▼
  Consumer chain: 08-wasm UpdateClient
        │
        ▼
  Client state height / root advanced
        │
        ▼
  App / contracts act on verified state
```

## Design tips for public verify

1. **Idempotent updates** — submitting an already-known tip should be a no-op or cheap reject, not a halt.  
2. **Multiple relayers** — prefer update formats that allow independent operators (historical update support where required).  
3. **Checksum pinning** — document the Wasm LC checksum your deployment expects.  
4. **Observability** — log client height, last update time, freeze status for public dashboards.  
5. **Separation of concerns** — header ingress is not proof verification; keep ZK proof submission as a separate message path.


## Related demos

See [Demos](../applications/demo-overview.md) for developer-facing verify paths that exercise public clients and contracts.
