# Hasher IBC gas

- image: `registry.terp.network/terp-core:v6.3.0-dev`
- topology: A=blake3 C=sha256; 08-wasm A↔C (HASHER_SMOKE)
- A TM handshake: skipped (08-wasm Hermes path; set HASHER_SKIP_TM_AC=0 to force)
- clients: C of A `08-wasm-0`; A of C `08-wasm-0`
- A→C path: ok

| action | path | client | gas | n | ok | note |
|---|---|---|---:|---:|---|---|
| ibc-wasm store-code | A+C | 08-wasm | 79484 | 1 | yes |  |
| RecvPacket | F 08-wasm | 08-wasm | 199979 | 1 | yes |  |

08-wasm LC verifies ICS-23 `HashOp` in software (portable). It does **not** import CosmWasm `blake3_256`, so the same bytecode can be stored on a foreign counterparty. Terp-native app contracts on A/B may use `deps.api.blake3_256` (`hash-blake`); C in this lab is a SHA-256 stand-in and must not require that host import.
