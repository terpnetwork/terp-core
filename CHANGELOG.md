# CHANGELOG

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
- Upgrade to WasmVM v1.2.0 
- Upgrade to cosmos-proto v1.0.0-beta.1
- Upgrade to spf13/cobra v1.6.1 
- Upgrade to Tendermint v0.34.24
- Upgrade to go-metrics v0.4.1 
- Upgrade to ics23      v0.9.0 
- Upgrade to btcutil v1.0.5
- Upgrade to ledger-go v0.9.3
- Upgrade to go-humanize v1.0.1-0.20200219035652-afde56e7acac 
- x/terp module for supplychainid & supplychain db core concepts
- Provide full x/upgrade features

## [v0.2.0](https://github.com/terpnetwork/terp-core/tree/v0.2.0) (2022-12-12)

[Full Changelog](https://github.com/terpnetwork/terp-core/compare/v0.1.1...v0.2.0)

- Provide source, builder and codehash information in store code proposal message
- Upgrade to Go v1.19 #1044
- Upgrade to Cosmos-sdk to v0.45.11
- Upgrade to IBC v4.2.0 with interchain-accounts v0.2.4
- Preserve contract history/ created date on genesis import
- Authz module integration - more granularity for WasmExecuteMsg authorizations
- StoreAndInstantiate gov proposal
- Start developer guide for contributors
- Fixes missing instantiate-anyof-addresses flag declaration for gov /
- Upgrade to Cosmos-sdk to v45.9 /#1052
- Add dependencies for protobuf and remove third_party forlder /#1030
- Check wasmvm version on startup #1029
- Allow AccessConfig to use a list of addresses instead of just a single address
- Make contract addresses predictable ("deterministic")
- Add query for the total supply of a coin #903 (larry0x)
- Upgrade go to v1.18 [#866]#866) (faddat)
- Upgrade to ibc-go v3.3.0 REQUIRES MIGRATION #1016
- Upgrade to cosmos-sdk v0.45.8 #964 (faddat)
- Upgrade wasmvm to v1.1.1 #1012, see wasmvm v1.1.1
- Add documentation how to add x/wasm to a new Cosmos SDK chain #876
- Upgrade keyring / go-keychain dependencies (removes deprecate warning) #957
- Make contract pinning an optional field in StoreCode proposals #972
- Add gRPC query for WASM params #889
- Expose Keepers in app.go? #881
- Remove unused flagProposalType flag in gov proposals #849
- Restrict code access config modifications #901
- Prevent migration to a restricted code #900
- Charge gas to unzip wasm code #898

### Notable changes:

- IBC fee middleware is setup in app.go. Please note that it can be enabled with new channels only. A nice read is this article.
- Authz for wasm contracts can be granted via terpd tx wasm grant and executed via terpd tx authz exec command
- Go v1.19 required to prevent a mixed chain setup with older versions. Just to be on the safe side.
- Store code proposal types have new metadata fields added that can help to build client side tooling to verify the wasm contract in the proposal
- BaseAccount and pruned vesting account types can be re-used for contracts addresses
- A new MsgInstantiateContract2 was introduced which is an additional value for message type events
- Store event contains a new attribute with the code checksum now
- New terpd tx wasm instantiate2 CLI command for predictable addresses on instantiation
- New cosmwasm_1_1 CosmWasm capability (former "feature") was introduced in cosmwasm/#1356 to support total supply queries
- Protobuf files are published to buf.build

## [v0.1.1](https://github.com/terpnetwork/terp-core/tree/v0.1.1) (2022-10-15)

[Full Changelog](https://github.com/terpnetwork/terp-core/compare/v0.27.0...v0.28.0)

**API Breaking**

No

**Fixed Bugs**

- Fix: Make events in reply completely determinisitic by stripping out anything coming from Cosmos SDK (not CosmWasm codebase) [\#917](https://github.com/CosmWasm/wasmd/pull/917) ([assafmo](https://github.com/assafmo))
- Reset Terp-Core Testing Scripts. These are to be reimplemented in a future issue.
- Reset Fuzz Testing. These are to be reimplemented in a future issue.

Migration notes:

- Contracts can no longer parse events from any calls except if they call another contract (or instantiate it, migrate it, etc).
  The main issue here is likely "Custom" queries from a blockchain, which want to send info (eg. how many tokens were swapped).
  Since those custom bindings are maintained by the chain, they can use the data field to pass any deterministic information
  back to the contract. We recommend using JSON encoding there with some documented format the contracts can parse out easily.
- For possible non-determinism issues, we also sort all attributes in events. Better safe than sorry.

## v0.1.0

This is a baseline... no CHANGELOG was maintained until this point
