# Pure PoW Path

The pure proof-of-work path tracks **Zcash headers** and treats finality as **confirmation depth** (enough accumulated work / blocks), without requiring Crosslink BFT finality.

This design sits next to the [light-client packaging](./light-clients.md) and [Crosslink](./crosslink.md) paths: same header sources and often the same 08-wasm deployment shape, different acceptance rule.

## Credits And Code

| Surface | Upstream | Link |
|---------|----------|------|
| Header / node stack | Zebra / Crosslink forks | [ShieldedLabs/zebra-crosslink](https://github.com/ShieldedLabs/zebra-crosslink), [permissionlessweb/zebra-crosslink](https://github.com/permissionlessweb/zebra-crosslink) |
| PoW test fixtures | Crosslink test data | `crosslink-test-data/test_pow_block_*.bin` (engineering fixtures, not a public API) |
| On-chain LC packaging | ICS-08 Wasm | [ibc-go 08-wasm](https://github.com/cosmos/ibc-go/tree/main/modules/light-clients/08-wasm), Eureka Wasm programs |

## When to prefer pure PoW

| Prefer pure PoW when… | Prefer Crosslink when… |
|-----------------------|-------------------------|
| You want a simpler trust story (work only) | You need faster economic finality |
| Crosslink is unavailable or out of scope | Your product assumes Crosslink-active networks |
| Bridging is low-frequency and depth is acceptable | UX needs short finality latency |

## Integrator notes

- **Client state** stores the trusted header tip (and parameters such as minimum depth).  
- **Updates** submit new headers (or header batches) that connect to the trusted chain and increase work.  
- **Acceptance rule**: application logic should only act on heights with depth ≥ your configured threshold.  
- **Test data**: PoW block fixtures under zebra-crosslink `crosslink-test-data/` are useful when writing verifiers.

Full pure-PoW 08-wasm packaging may lag or share modules with the Crosslink client tree. Always check current Eureka / zebra-crosslink programs for which Wasm artifacts are production-ready.

## Differences from Crosslink (developer view)

| Topic | Pure PoW | Crosslink |
|-------|----------|-----------|
| Finality signal | Confirmation depth | Hybrid finality certificates / Crosslink layer |
| Update payload | Headers / work proofs | Finality + parent PoW linkage as designed by client |
| Failure mode | Reorg within depth | Conflicting finality / freeze policies |
| Ops dependency | Zcash header source | Zcash + Crosslink participants |

## Combining with proofs

Public inputs to a ZK circuit can bind to a **block hash**, **nullifier set root**, or **note commitment tree root** that your contract only trusts after the pure PoW (or Crosslink) client has accepted that height. Keep the light-client update and the `proof_instance_verify` call in a deliberate order inside your application protocol.

## See also

- [Crosslink](./crosslink.md)  
- [Design Survey](./design-survey.md)  
- [Headers and ingress](./ingress.md)  
