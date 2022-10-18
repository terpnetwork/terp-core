# CHANGELOG

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]



## [v0.1.1](https://github.com/terpnetwork/terp-core/tree/v0.1.1) (2022-10-15)

[Full Changelog](https://github.com/terpnetwork/terp-core/compare/v0.27.0...v0.28.0)

**API Breaking**

No

**Fixed Bugs**

- Fix: Make events in reply completely determinisitic by stripping out anything coming from Cosmos SDK (not CosmWasm codebase) [\#917](https://github.com/CosmWasm/wasmd/pull/917) ([assafmo](https://github.com/assafmo))
- Reset Terp-Core Testing Scripts. These are to be reimplemented in a future issue.
- Reset Fuzz Testing. These are to be reimplemented in a future issue. 

Migration notes:

* Contracts can no longer parse events from any calls except if they call another contract (or instantiate it, migrate it, etc).
The main issue here is likely "Custom" queries from a blockchain, which want to send info (eg. how many tokens were swapped).
Since those custom bindings are maintained by the chain, they can use the data field to pass any deterministic information
back to the contract. We recommend using JSON encoding there with some documented format the contracts can parse out easily.
* For possible non-determinism issues, we also sort all attributes in events. Better safe than sorry.

## v0.1.0

This is a baseline... no CHANGELOG was maintained until this point