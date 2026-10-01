# Hasher IBC gas

- timestamp: `2026-09-14T09:14:43Z` (overwritten each run)
- arch: `aarch64` (this run fills `gas_aarch64`; other arch columns reserved)
- image: `registry.terp.network/terp-core:v6.3.0-dev`
- topology: same-hasher 07-tendermint pairs (no 08-wasm)
- A TM handshake: native pairs
- clients: C of A `—`; A of C `—`
- A→C path: n/a (native TM pairs)

| action | path | client | n | ok | gas | gas_aarch64 | gas_amd64 | note |
|---|---|---|---:|---|---:|---:|---:|---|
| TM handshake | blake3↔blake3 | 07-tendermint | 0 | no | 0 | 0 | — | Relayer error on hermes: create connection exit 1: {"timestamp":"2026-09-14T09:10:18.209558Z","level":"INFO","fields":{"… |
| TM handshake | sha256↔sha256 | 07-tendermint | 0 | no | 0 | 0 | — | timeout waiting for RecvPacket / dest balance |

08-wasm LC verifies ICS-23 `HashOp` in software (portable). It does **not** import CosmWasm `blake3_256`, so the same bytecode can be stored on a foreign counterparty. Terp-native app contracts on A/B may use `deps.api.blake3_256` (`hash-blake`); C in this lab is a SHA-256 stand-in and must not require that host import.
