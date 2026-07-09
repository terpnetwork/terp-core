<!--
order: 0
title: "HashMerchant Overview"
parent:
  title: "hashmerchant"
-->

# `hashmerchant`

## Abstract

The `x/hashmerchant` module implements a **verifiable Merkle reflection market** for Terp Network.

It allows validators to attest to foreign-chain state roots (Ethereum, Cosmos Hub, other IBC chains) during CometBFT consensus using **ABCI++ vote extensions**. When a supermajority of validators agree on a root, the module writes it on-chain and delivers it to registered CosmWasm contracts via `sudo` callbacks.

This gives smart contracts on Terp **trustless, real-time knowledge of external chain state** without requiring a full light client. Contracts can then verify Merkle inclusion proofs against the confirmed root to prove facts about foreign state (token balances, NFT ownership, contract storage values) entirely on-chain.

Foreign-chain roots are optionally **re-hashed into Pallas-curve-compatible representations**, making them usable inside ZK circuits built on the Halo 2 proving system. This enables privacy-preserving proofs of foreign-chain state (e.g., proving you hold an ERC-20 token without revealing your address).

### How It Works (30-second version)

1. **Governance registers a foreign chain** (e.g., `ethereum-mainnet`) with its hash algorithms.
2. **Validators run a sidecar** that reads the foreign chain's latest state root and injects it into their vote extension during each consensus round.
3. **The module tallies attestations** — if 2/3+ of voting power agrees on a root, it becomes a **confirmed HashRoot** stored on-chain.
4. **Registered contracts receive the confirmed root** via a `sudo` callback, enabling them to verify Merkle proofs against it.
5. **Contracts pay escrow** in TERP to stay registered — expired escrow disables callbacks automatically.

## Contents

1. **[Concepts](01_concepts.md)**
2. **[State](02_state.md)**
3. **[State Transitions](03_state_transitions.md)**
4. **[Messages](04_messages.md)**
5. **[Vote Extensions](05_vote_extensions.md)**
6. **[Sudo Interface](06_sudo_interface.md)**
7. **[Events](07_events.md)**
8. **[Parameters](08_parameters.md)**
9. **[Example: Token Ownership Proof](09_example_token_ownership.md)**
