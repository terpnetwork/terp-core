# Glossary

| Term | Meaning |
|------|---------|
| **ZK-CosmWasm** | CosmWasm stack with proof-verification-oriented host support and circuit caching |
| **zkid** | Application-assigned logical circuit id resolved to a content-addressed circuit key |
| **VK** | Verifying key (with embedded constraint system in this stack’s version-2 format) |
| **CircuitFooter** | 80-byte trailer: prover/curve/`k`/instances, section lengths, dual SHA-256 checksums |
| **circuit_key** | 72-byte content key: `param_key ‖ vk_key` |
| **params** | Halo2 (or similar) commitment parameters; often shared for a given `k` |
| **Path A** | Host-cache load of VK after CircuitInfo (avoids pulling full blob over querier) |
| **Cold path** | Circuit query + deserialize when cache misses |
| **Crosslink** | Hybrid finality light-client / node path over Zcash PoW |
| **Pure PoW** | Confirmation-depth light-client path on Zcash headers only |
| **08-wasm** | IBC light client whose logic runs as CosmWasm Wasm bytecode |
| **Capability** | Contract/host negotiation via `requires_*` Wasm exports (not Cargo features) |
| **vote-sdk** | Shielded voting appchain and circuits (monorepo) |
| **terp-rs smart-accounts** | Grant-aligned authenticator contracts + suite under `contracts/smart-accounts/` |
| **FlyClient** | Succinct PoW light-client approach (ZIP-221 lineage) |
| **Cw-Orch** | cw-orchestrator: typed CosmWasm testing and scripting |
| **Ecosystem** | Application-layer and light-client designs beyond the core VM |
