
# Terp-Core

[![license](https://img.shields.io/github/license/terpnetwork/terp-core.svg)](https://github.com/terpnetwork/terp-core/blob/main/LICENSE)

For issues & disclosure, see [SECURITY.md](SECURITY.md)

## Stability

**This is beta software** It is run in some production systems, but we cannot yet provide a stability guarantee
and have not yet gone through and audit of this codebase.

Thank you to all projects who have run this code in your mainnets and testnets and
given feedback to improve stability.

## Quick Start

```sh
## requires go installed
make install
# run `terpd version` to confirm installation was successful
```

## Testing

```sh
# to view all go package testing commands
make test
# to view all interchaintest commands
make e2e
# to view all manual bash script test commands
make tsh
```

## Docker

```sh
# builds image labeled as terpnetwork/terp-core:local                  
make docker-build
```

## Protobuf

```sh
# generates the latest type definitons,sets them into our modules (./x/*)
make proto-gen
# generates swagger api definitions
make proto-swagger
make proto-pulsar
```

### Dev server

A dockerized development server is available for use, including accounts with balances, a testnet-faucet for seeding new accounts with balances. To compile and spin-up and instance, [read more here](./docker/README.md).

### Networks

**A comprehensive list of current and historical networks** can be found [here](https://github.com/terpnetwork/networks). This includes our genesis files, upgrade information, and more.

## Contributors

This framework is like a craft genetics lineage, one that has been fine tuned with love, trial and error, patience, and iterations. The following is a list of teams, companies, and contributors that are impactful to Terp Network's creation, massive respect!

- CosmosSDK Contributors
- CosmWasm / Wasmd Contributors
- IBC Protocol Contributors
- Juno's Core-1 Contributors  
- Hard-nett - TerpNet Foundation DAO
- Xiti - TerpNet Foundation DAO
- Alex Johnson - Chronic Token

If we forgot you in this list, let us know or open a PR ::)

## DISCLAIMER

TERP-CORE SOFTWARE IS PROVIDED “AS IS”, AT YOUR OWN RISK, AND WITHOUT WARRANTIES OF ANY KIND. No developer or entity involved in running terp-core software will be liable for any claims or damages whatsoever associated with your use, inability to use, or your interaction with other users of Terp Network, including any direct, indirect, incidental, special, exemplary, punitive or consequential damages, or loss of profits, cryptocurrencies, tokens, or anything else of value. Although Discover Decentralization, LLC and it's affiliates developed the initial code for Terp-Core, it does not own or control the Terp Network, which is run by a decentralized validator set.
