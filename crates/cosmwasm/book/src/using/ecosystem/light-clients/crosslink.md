# Crosslink Path

Crosslink is Zcash’s **hybrid finality** direction: a BFT-style finality layer coordinated with the underlying PoW chain. For CosmWasm / IBC integrators, the practical artifact is an **ICS-08 Wasm light client** that tracks Crosslink-aware state.

## Credits And Code

These projects are maintained by their upstream teams; this guide only maps integrator-facing surfaces.

| Component | Upstream | Repository |
|-----------|----------|------------|
| Node / consensus / tooling | Zebra / Crosslink lineage (Shielded Labs et al.) | [ShieldedLabs/zebra-crosslink](https://github.com/ShieldedLabs/zebra-crosslink) · [permissionlessweb/zebra-crosslink](https://github.com/permissionlessweb/zebra-crosslink) |
| CosmWasm 08-wasm client | Cosmos Solidity IBC Eureka programs | [cw-ics08-wasm-crosslink](https://github.com/cosmos/solidity-ibc-eureka/tree/main/programs/cw-ics08-wasm-crosslink) |
| ICS-08 module (host chain) | IBC-Go | [cosmos/ibc-go — 08-wasm](https://github.com/cosmos/ibc-go/tree/main/modules/light-clients/08-wasm) |
| PoW-adjacent fixtures | Same Crosslink test data trees | `crosslink-test-data/` in zebra-crosslink — also used for [pure PoW](./pow.md) engineering tests |

## Integrator shape (08-wasm)

Following the same pattern as other 08-wasm clients:

1. **Build** the Wasm light-client contract (optimizer / Just targets in the Eureka programs tree).  
2. **Store** bytecode on the host chain via 08-wasm governance / store messages ([IBC docs](https://ibc.cosmos.network/)).  
3. **CreateClient** with:
   - Wasm checksum of the stored bytecode  
   - Initial client + consensus state for the Crosslink / Zcash view you track  
4. **UpdateClient** as finality advances (relayer-submitted updates).  
5. **Verify membership** (when supported by the client) against committed IBC or application state roots.

Misbehavior and freeze policies are client-specific; expect freeze-on-conflicting-updates patterns similar to other production light clients, with governance recovery.

## Relationship to ZK-CosmWasm VM

- Light clients **do not replace** `proof_instance_verify`. They establish **which chain tip / root** you trust.  
- Contracts may combine both: e.g. verify a Halo2 proof whose public inputs bind to a header or state root already accepted by a light client.  
- Some designs may even call `proof_instance_verify` during validation of zero-knowledge light-client proofs.

## Pure PoW fallback

If you do not want Crosslink committee assumptions, use confirmation depth only — [Pure PoW Path](./pow.md) — ideally with the same header/fixture sources.

## Developer checklist

- [ ] Confirm target chain supports **08-wasm** light clients  
- [ ] Pin a specific Wasm checksum; upgrade via governance when the LC contract changes  
- [ ] Align relayer software with the client’s update message schema  
- [ ] Test against fixtures under zebra-crosslink / `crosslink-test-data` when available  
- [ ] Document whether your product requires Crosslink finality or falls back to pure PoW  
- [ ] Confirm IBC **v1 vs v2** expectations on the consumer chain  

## Further reading

- Zebra / Crosslink README in the zebra-crosslink repository  
- Program README: Eureka `programs/cw-ics08-wasm-crosslink/`  
- Draft settlement context: `ZCASH_INTEGRATION.md` in this CosmWasm fork  
