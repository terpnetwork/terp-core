# Hasher IBC gas

- image: `registry.terp.network/terp-core:v6.3.0-dev`
- topology: A=blake3 B=hybrid C=sha256; TM B→C; 08-wasm A↔C
- A TM handshake: skipped (08-wasm Hermes path; set HASHER_SKIP_TM_AC=0 to force)
- clients: C of A `08-wasm-1`; A of C `08-wasm-0`
- A→C path: ok

| action | path | client | gas | n | ok | note |
|---|---|---|---:|---:|---|---|
| ibc-wasm store-code | A+C | 08-wasm | 79484 | 1 | yes |  |
| RecvPacket | H 07-tendermint | 07-tendermint | 186947 | 1 | yes |  |
| UpdateClient | H 07-tendermint | 07-tendermint | 186947 | 1 | yes |  |
| RecvPacket | F 08-wasm | 08-wasm | 189010 | 1 | yes |  |
| CreateClient | B→C | 07-tendermint | 94073 | 1 | yes | TM |
| ConnOpenInit | B→C | 07-tendermint | 56635 | 1 | yes | TM |
| ConnOpenAck | B→C | 07-tendermint | 129023 | 1 | yes | TM |
| ChanOpenInit | B→C | 07-tendermint | 62907 | 1 | yes | TM |
| ChanOpenAck | B→C | 07-tendermint | 114473 | 1 | yes | TM |
| UpdateClient | B→C | 07-tendermint | 114473 | 3 | yes | TM |
| CreateClient | B→C | 07-tendermint | 94073 | 1 | yes | TM |
| ConnOpenTry | B→C | 07-tendermint | 137141 | 1 | yes | TM |
| ConnOpenConfirm | B→C | 07-tendermint | 112289 | 1 | yes | TM |
| ChanOpenTry | B→C | 07-tendermint | 128314 | 1 | yes | TM |
| ChanOpenConfirm | B→C | 07-tendermint | 114435 | 1 | yes | TM |
| UpdateClient | B→C | 07-tendermint | 114435 | 5 | yes | TM |
| CreateClient | A→C | 08-wasm | 100452 | 1 | yes | 08-wasm |
| ConnOpenInit | A→C | 08-wasm | 59922 | 1 | yes | 08-wasm |
| ConnOpenAck | A→C | 08-wasm | 146474 | 1 | yes | 08-wasm |
| ChanOpenInit | A→C | 08-wasm | 66599 | 1 | yes | 08-wasm |
| ChanOpenAck | A→C | 08-wasm | 128600 | 1 | yes | 08-wasm |
| UpdateClient | A→C | 08-wasm | 130303 | 4 | yes | 08-wasm |
| Acknowledgement | A→C | 08-wasm | 130303 | 1 | yes | 08-wasm |
| CreateClient | A→C | 08-wasm | 86797 | 1 | yes | 08-wasm |
| ConnOpenTry | A→C | 08-wasm | 151828 | 1 | yes | 08-wasm |
| ConnOpenConfirm | A→C | 08-wasm | 125332 | 1 | yes | 08-wasm |
| ChanOpenTry | A→C | 08-wasm | 141888 | 1 | yes | 08-wasm |
| ChanOpenConfirm | A→C | 08-wasm | 128132 | 1 | yes | 08-wasm |
| UpdateClient | A→C | 08-wasm | 141888 | 8 | yes | 08-wasm |
| Timeout | path-ac | 08-wasm | 0 | 0 | no | expired transfer: Config error: wasm tx exit 1: Error: relative timeouts using block height is not supported
Usage:
  terpd tx ibc-transfer transfer [src-port] [src-channel] [receiver] [coin] [flags]

Examples:
terpd tx ibc-transfer transfer [src-port] [src-channel] [receiver] [coin]

Flags:
      --absolute-timeouts               Timeout flags are used as absolute timeouts.
  -a, --account-number uint             The account number of the signing account (offline mode only)
      --aux                             Generate aux signer data instead of sending a tx
  -b, --broadcast-mode string           Transaction broadcasting mode (sync|async) (default "sync")
      --chain-id string                 The network chain ID
      --dry-run                         ignore the --gas flag and perform a simulation of a transaction, but don't broadcast it (when enabled, the local Keybase is not accessible)
      --fee-granter string              Fee granter grants fees for the transaction
      --fee-payer string                Fee payer pays fees for the transaction instead of deducting from the signer
      --fees string                     Fees to pay along with transaction; eg: 10uatom
      --from string                     Name or address of private key with which to sign
      --gas string                      gas limit to set per-transaction; set to "auto" to calculate sufficient gas automatically. Note: "auto" option doesn't always report accurate results. Set a valid coin value to adjust the result. Can be used instead of "fees". (default 200000)
      --gas-adjustment float            adjustment factor to be multiplied against the estimate returned by the tx simulation; if the gas limit is set manually this flag is ignored (default 1)
      --gas-prices string               Gas prices in decimal format to determine the transaction fee (e.g. 0.1uatom)
      --generate-only                   Build an unsigned transaction and write it to STDOUT (when enabled, the local Keybase only accessed when providing a key name)
  -h, --help                            help for transfer
      --keyring-backend string          Select keyring's backend (os|file|kwallet|pass|test|memory) (default "os")
      --keyring-dir string              The client Keyring directory; if omitted, the default 'home' directory will be used
      --ledger                          Use a connected Ledger device
      --memo string                     Memo to be sent along with the packet.
      --node string                     <host>:<port> to CometBFT rpc interface for this chain (default "tcp://localhost:26657")
      --note string                     Note to add a description to the transaction (previously --memo)
      --offline                         Offline mode (does not allow any online functionality)
  -o, --output string                   Output format (text|json) (default "json")
      --packet-timeout-height string    Packet timeout block height in the format {revision}-{height}. (default "0-0")
      --packet-timeout-timestamp uint   Packet timeout timestamp in nanoseconds from now. Default is 10 minutes. On IBC v1 protocol, either timeout timestamp or timeout height must be set. On IBC v2 protocol timeout timestamp must be set. (default 600000000000)
  -s, --sequence uint                   The sequence number of the signing account (offline mode only)
      --sign-mode string                Choose sign mode (direct|amino-json|direct-aux), this is an advanced feature
      --timeout-duration duration       TimeoutDuration is the duration the transaction will be considered valid in the mempool. The transaction's unordered nonce will be set to the time of transaction creation + the duration value passed. If the transaction is still in the mempool, and the block time has passed the time of submission + TimeoutDuration, the transaction will be rejected.
      --timeout-height uint             DEPRECATED: Please use --timeout-duration instead. Set a block timeout height to prevent the tx from being committed past a certain height
      --tip string                      Tip is the amount that is going to be transferred to the fee payer on the target chain. This flag is only valid when used with --aux, and is ignored if the target chain didn't enable the TipDecorator
      --unordered                       Enable unordered transaction delivery; must be used in conjunction with --timeout-duration
  -y, --yes                             Skip tx broadcasting prompt confirmation

Global Flags:
      --home string                directory for config and data (default "/terpd/.terpd")
      --log_format string          The logging format (json|plain) (default "plain")
      --log_level string           The logging level (trace|debug|info|warn|error|fatal|panic|disabled or '*:<level>,<key>:<level>') (default "info")
      --log_no_color               Disable colored logs
      --trace                      print out full stack trace on errors
      --verbose_log_level string   The logging level (trace|debug|info|warn|error|fatal|panic|disabled|none) to use when performing operations which require extra verbosity (such as upgrades). When enabled, verbose mode disables any custom log filters. Set this to none to make verbose mode equivalent to normal logging. (default "debug")

relative timeouts using block height is not supported
 |
| 08-wasm Pin() | A+C | 08-wasm | 0 | 1 | yes | ibc-go store-code already Pin()s checksum; new clients/channels on warm VM |
| RecvPacket | A→C warm | 08-wasm | 189876 | 1 | yes | warm VM after store-code Pin() |
| CreateClient | A→C warm | 08-wasm | 86894 | 1 | yes | warm |
| ConnOpenInit | A→C warm | 08-wasm | 59942 | 1 | yes | warm |
| ConnOpenAck | A→C warm | 08-wasm | 147271 | 1 | yes | warm |
| ChanOpenInit | A→C warm | 08-wasm | 66613 | 1 | yes | warm |
| ChanOpenAck | A→C warm | 08-wasm | 129271 | 1 | yes | warm |
| UpdateClient | A→C warm | 08-wasm | 130338 | 4 | yes | warm |
| Acknowledgement | A→C warm | 08-wasm | 130338 | 1 | yes | warm |
| CreateClient | A→C warm | 08-wasm | 86894 | 1 | yes | warm |
| ConnOpenTry | A→C warm | 08-wasm | 154293 | 1 | yes | warm |
| ConnOpenConfirm | A→C warm | 08-wasm | 126496 | 1 | yes | warm |
| ChanOpenTry | A→C warm | 08-wasm | 142058 | 1 | yes | warm |
| ChanOpenConfirm | A→C warm | 08-wasm | 128167 | 1 | yes | warm |
| UpdateClient | A→C warm | 08-wasm | 128167 | 7 | yes | warm |

08-wasm LC verifies ICS-23 `HashOp` in software (portable). It does **not** import CosmWasm `blake3_256`, so the same bytecode can be stored on a foreign counterparty. Terp-native app contracts on A/B may use `deps.api.blake3_256` (`hash-blake`); C in this lab is a SHA-256 stand-in and must not require that host import.
