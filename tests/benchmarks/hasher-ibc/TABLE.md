# Hasher IBC gas

- timestamp: `2026-09-14T09:17:52Z` (overwritten each run)
- arch: `aarch64` (this run fills `gas_aarch64`; other arch columns reserved)
- image: `registry.terp.network/terp-core:v6.3.0-dev`
- topology: same-hasher 07-tendermint pairs (no 08-wasm)
- A TM handshake: native pairs
- clients: C of A `—`; A of C `—`
- A→C path: n/a (native TM pairs)

| action | path | client | n | ok | gas | gas_aarch64 | gas_amd64 | note |
|---|---|---|---:|---|---:|---:|---:|---|
| RecvPacket | H 07-tendermint | 07-tendermint | 1 | yes | 187757 | 187757 | — |  |
| CreateClient | sha256↔sha256 | 07-tendermint | 1 | yes | 94441 | 94441 | — | sha256 |
| ConnOpenInit | sha256↔sha256 | 07-tendermint | 1 | yes | 56683 | 56683 | — | sha256 |
| ConnOpenAck | sha256↔sha256 | 07-tendermint | 1 | yes | 129627 | 129627 | — | sha256 |
| ChanOpenInit | sha256↔sha256 | 07-tendermint | 1 | yes | 62931 | 62931 | — | sha256 |
| ChanOpenAck | sha256↔sha256 | 07-tendermint | 1 | yes | 115043 | 115043 | — | sha256 |
| UpdateClient | sha256↔sha256 | 07-tendermint | 4 | yes | 116623 | 116623 | — | sha256 |
| Acknowledgement | sha256↔sha256 | 07-tendermint | 1 | yes | 116623 | 116623 | — | sha256 |
| CreateClient | sha256↔sha256 | 07-tendermint | 1 | yes | 94441 | 94441 | — | sha256 |
| ConnOpenTry | sha256↔sha256 | 07-tendermint | 1 | yes | 137723 | 137723 | — | sha256 |
| ConnOpenConfirm | sha256↔sha256 | 07-tendermint | 1 | yes | 112790 | 112790 | — | sha256 |
| ChanOpenTry | sha256↔sha256 | 07-tendermint | 1 | yes | 128777 | 128777 | — | sha256 |
| ChanOpenConfirm | sha256↔sha256 | 07-tendermint | 1 | yes | 114893 | 114893 | — | sha256 |
| UpdateClient | sha256↔sha256 | 07-tendermint | 6 | yes | 128777 | 128777 | — | sha256 |
| RecvPacket | sha256↔sha256 | 07-tendermint | 1 | yes | 187757 | 187757 | — | sha256 |

08-wasm LC verifies ICS-23 `HashOp` in software (portable). It does **not** import CosmWasm `blake3_256`, so the same bytecode can be stored on a foreign counterparty. Terp-native app contracts on A/B may use `deps.api.blake3_256` (`hash-blake`); C in this lab is a SHA-256 stand-in and must not require that host import.
