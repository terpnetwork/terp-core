# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [huckleberry](https://github.com/terpnetwork/terp-core/tree/hard-nett/huckleberry)
- Huckleberry Patch + dependency bumps

[Full Changelog](https://github.com/terpnetwork/terp-core/compare/huckleberry...MAIN)

## [v1.0.0-proto](https://github.com/terpnetwork/terp-core/tree/hard-nett/v1.0.0-proto)

[Full Changelog](https://github.com/terpnetwork/terp-core/compare/v1.0.0-proto..huckleberry)

Terpd v1.0.0-stable has a large dependency upgrade of the Cosmos SDK version from 0.45 to 0.47. Please read notable changes and migration notes
below to learn more!

- Bump IBC-Go to v7.0.1 to include the fix for the huckleberry security advisory.[\#1418](https://github.com/CosmWasm/wasmd/pull/1418)
- Fix cli update-instantiate-config command [/#1415](https://github.com/CosmWasm/wasmd/pull/1415)
- Import export simulation test for `x/wasm` is missing [\#1372](https://github.com/CosmWasm/wasmd/issues/1372)
- Better tracking of CosmWasm capabilities [\#1341](https://github.com/CosmWasm/wasmd/issues/1341)
- Rename `lastIDKey` key [\#1182](https://github.com/CosmWasm/wasmd/issues/1182)
- Use ICS4Wrapper to send raw IBC packets & fix Fee middleware in wasm stack \(backport \#1375\) [\#1379](https://github.com/CosmWasm/wasmd/pull/1379)
- Add wasm store to import-export sims [\#1374](https://github.com/CosmWasm/wasmd/pull/1374)
- Bumped SDK to 0.47.2 and CometBFT to 0.37.1 [\#1369](https://github.com/CosmWasm/wasmd/pull/1369)
- Remove starport config [\#1359](https://github.com/CosmWasm/wasmd/pull/1359)
- Proper v1 gov support for wasm msg types [\#1301](https://github.com/CosmWasm/wasmd/issues/1301)
- Cleanup `ErrNotFound` cases [\#1258](https://github.com/CosmWasm/wasmd/issues/1258)
- New proto annotations  [\#1157](https://github.com/CosmWasm/wasmd/issues/1157)
- Simulations with '--dry-run' return an error [\#713](https://github.com/CosmWasm/wasmd/issues/713)
- Add wasmvm decorator option [\#1348](https://github.com/CosmWasm/wasmd/pull/1348)
- More verbose error message [\#1354](https://github.com/CosmWasm/wasmd/pull/1354)
- Remove gogo/protobuf from the 47 build's dependencies [\#1281](https://github.com/CosmWasm/wasmd/issues/1281)
- Set final ibc-go version [\#1271](https://github.com/CosmWasm/wasmd/issues/1271)
- Upgrade to cosmos-sdk proto 0.47.x [\#1148](https://github.com/CosmWasm/wasmd/issues/1148)

### Notable changes:
- If you are not coming from v0.32.0, please see the "Notables changes" below, first. Especially about CometBFT.
- IBC-Go is a new major version including the "hucklebery" security fix. See [v7.0.1](https://github.com/cosmos/ibc-go/releases/tag/v7.0.1).
- SDK 47 support is a big step from the SDK 45 version supported before. Make sure to read the upgrade guide for the SDK
  before applying any changes. Links below. 
- Some advice from working with SDK 47 that may affect you, too:    
  - The SDK version includes some key store migration for the CLI. Make sure you backup your private keys before 
    testing this! You can not switch back to v0.45 afaik
  - Take care that you use the goleveldb version used in the SDK. A transitive dependency may change it which caused 
    failing queries on a running server: `Error: rpc error: code = InvalidArgument desc = failed to load state at height 1; version does not exist (latest height: 1): invalid request`
    Ensure this in go.mod:
    `github.com/syndtr/goleveldb => github.com/syndtr/goleveldb v1.0.1-0.20210819022825-2ae1ddf74ef7`
  - With custom modules, use the new proto-builder version (Makefile) to let proto types register with the correct registry
  - Ensure that all `ParameterChangeProposal` are completed before the upgrade or migrate them to `v1.gov`. SDK and wasm 
    modules execute a migration before so that these proposals would not have an affect.
  - Attribute keys/ values in events are strings and not bytes in CometBFT. This may break clients
  - CLI: `add-genesis-account`, `gentx,add-genesis-account`, `collect-gentxs` and others are now under genesis command as parent
  - CLI: `--broadcast-mode block` was removed. You need to query the result for a TX with `terpd q tx <hash>` instead
- New CLI param to skip checkLibwasmVersion `--wasm.skip_wasmvm_version_check`
- The wasmvm version includes the [Cherry](https://github.com/CosmWasm/advisories/blob/main/CWAs/CWA-2023-002.md) bugfix
- New behaviour for Contracts returning errors on IBC packet receive.
  - Let contract fully abort IBC receive in certain case [\#1220](https://github.com/CosmWasm/wasmd/issues/1220)
  - Return non redacted error content on IBC packet recv [\#1289](https://github.com/CosmWasm/wasmd/issues/1289)
  - Wasm and submessage events follow SDK transaction behaviour. Not persisted on state rollback  
  - Full error message is stored in event [\#1288](https://github.com/CosmWasm/wasmd/issues/1288)
  - See updates in cosmwasm [doc](https://github.com/CosmWasm/cosmwasm/pull/1646/files?short_path=f9839d7#diff-f9839d73197185aaec052064f43a324bd9309413f3ad36183c3247580b1b6669) for more details.  
- The SDK v0.45.15 replaces Tendermint with CometBFT. This requires a `replace` statement in `go.mod`. 
  Please read their [release notes](https://github.com/cosmos/cosmos-sdk/releases/tag/v0.45.15) carefully for details
- The SDK v0.45.x line reached its end-of-life.
- CometBFT includes some [breaking changes](https://github.com/cometbft/cometbft/blob/v0.34.27/CHANGELOG.md#breaking-changes) 
 

### Migration notes:
- This release contains a [state migration](./x/wasm/migrations/v2) for the terpd module that stores 
  the params in the module store.
- SDK v0.47 comes with a lot of api/state braking changes to previous versions. Please see their [upgrade guide](https://github.com/cosmos/cosmos-sdk/blob/main/UPGRADING.md#v047x)
  which contains a lot of helpful details.
- Please read the [migration guide](https://github.com/cosmos/ibc-go/tree/v7.0.0/docs/migrations) for IBC-Go [v7.0.0](https://github.com/cosmos/ibc-go/releases/tag/v7.0.0) carefully

- Redesign IBC on packet recv error/ result.Err handling [\#1358](https://github.com/CosmWasm/wasmd/pull/1358)
- Use ICS4Wrapper to send raw IBC packets & fix Fee middleware in wasm stack [\#1375](https://github.com/CosmWasm/wasmd/pull/1375)
- Better configuration for CosmWasm capabilities [\#1361](https://github.com/CosmWasm/wasmd/pull/1361)
- Remove old starport config - unused [\#1359](https://github.com/CosmWasm/wasmd/pull/1359)
- Better error message for wasm file limit exceeded [\#1354](https://github.com/CosmWasm/wasmd/pull/1354)
- CLI param to bypass version check for wasm lib [\#1338](https://github.com/CosmWasm/wasmd/pull/1338)
- Cleanup ErrNotFound cases [\#1343](https://github.com/CosmWasm/wasmd/pull/1343)
- Add wasmvm decorator option [\#1350](https://github.com/CosmWasm/wasmd/pull/1350)
- Bump github.com/prometheus/client_golang from 1.14.0 to 1.15.0 [/#1336](https://github.com/CosmWasm/wasmd/pull/1336)
- Update OnRecvPacket method to panic when an error is returned by the VM [/#1303](https://github.com/CosmWasm/wasmd/pull/1303)
- Removed the unnecessary usage of ErrInvalidMsg [\#1317](https://github.com/CosmWasm/wasmd/pull/1317)
- Upgrade wasmvm to v1.2.3 [\#1355](https://github.com/CosmWasm/wasmd/pull/1355), see [wasmvm v1.2.3](https://github.com/CosmWasm/wasmvm/releases/tag/v1.2.3)
- Upgrade to Cosmos-SDK v0.45.15 including CometBFT [\#1284](https://github.com/CosmWasm/wasmd/pull/1284)
- This release does not include any state migrations but breaking changes that require a coordinated chain upgrade
- remove x/terp module for supplychainid & supplychain db core concepts

## [v0.4.0](https://github.com/terpnetwork/terp-core/tree/hard-nett/v0.4.0)

[Full Changelog](https://github.com/terpnetwork/terp-core/compare/v0.4.0...huckleberry)

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