# CHANGELOG

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## V0.1.0 (*wasmd* [v0.29.0](https://github.com/CosmWasm/wasmd/tree/v0.29.0)) (2022-10-10)
[Full Changelog](https://github.com/CosmWasm/wasmd/compare/v0.28.0...v0.29.0)
- Add dependencies for protobuf and remove third_party forlder [/#1030](https://github.com/CosmWasm/wasmd/pull/1030)
- Check wasmvm version on startup [\#1029](https://github.com/CosmWasm/wasmd/pull/1029/) 
- Allow AccessConfig to use a list of addresses instead of just a single address [\#945](https://github.com/CosmWasm/wasmd/issues/945)
- Make contract addresses predictable \("deterministic"\) [\#942](https://github.com/CosmWasm/wasmd/issues/942)
- Add query for the total supply of a coin [\#903](https://github.com/CosmWasm/wasmd/pull/903) ([larry0x](https://github.com/larry0x))
- Upgrade go to v1.18 [\#866](https://github.com/CosmWasm/wasmd/pull/866/) ([faddat](https://github.com/faddat))
- Upgrade to ibc-go v3.3.0 REQUIRES [MIGRATION](https://github.com/cosmos/ibc-go/blob/v3.2.3/docs/migrations/support-denoms-with-slashes.md) [\#1016](https://github.com/CosmWasm/wasmd/pull/1016)
- Upgrade to cosmos-sdk v0.45.8 [\#964](https://github.com/CosmWasm/wasmd/pull/964/) ([faddat](https://github.com/faddat))
- Upgrade wasmvm to v1.1.1 [\#1012](https://github.com/CosmWasm/wasmd/pull/1012), see [wasmvm v1.1.1](https://github.com/CosmWasm/wasmvm/releases/tag/v1.1.1)
- Add documentation how to add x/wasm to a new Cosmos SDK chain [\#876](https://github.com/CosmWasm/wasmd/issues/876)
- Upgrade keyring / go-keychain dependencies (removes deprecate warning) [\#957](https://github.com/CosmWasm/wasmd/issues/957)
- Make contract pinning an optional field in StoreCode proposals  [\#972](https://github.com/CosmWasm/wasmd/issues/972)
- Add gRPC query for WASM params [\#889](https://github.com/CosmWasm/wasmd/issues/889)
- Expose Keepers in app.go? [\#881](https://github.com/CosmWasm/wasmd/issues/881)
- Remove unused `flagProposalType` flag in gov proposals [\#849](https://github.com/CosmWasm/wasmd/issues/849)
- Restrict code access config modifications [\#901](https://github.com/CosmWasm/wasmd/pull/901)
- Prevent migration to a restricted code [\#900](https://github.com/CosmWasm/wasmd/pull/900)
- Charge gas to unzip wasm code [\#898](https://github.com/CosmWasm/wasmd/pull/898)

### Notable changes:
- BaseAccount and pruned vesting account types can be re-used for contracts addresses
- A new [MsgInstantiateContract2](https://github.com/CosmWasm/wasmd/pull/1014/files#diff-bf58b9da4b674719f07dd5421c532c1ead13a15f8896b59c1f724215d2064b73R75) was introduced which is an additional value for `message` type events
- Store event contains a new attribute with the code checksum now
- New `wasmd tx wasm instantiate2` CLI command for predictable addresses on instantiation
- New `cosmwasm_1_1` CosmWasm capability (former "feature") was introduced in [cosmwasm/#1356](https://github.com/CosmWasm/cosmwasm/pull/1356) to support total supply queries 
- Protobuf files are published to [buf.build](https://buf.build/cosmwasm/wasmd/docs/main:cosmwasm.wasm.v1)

### Migration notes:
- See ibc-go [migration notes](https://github.com/cosmos/ibc-go/blob/v3.3.0/docs/migrations/support-denoms-with-slashes.md)

## 0.0.1

This is a baseline... no CHANGELOG was maintained until this point