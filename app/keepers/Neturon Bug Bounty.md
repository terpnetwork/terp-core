# Neturon Bug Bounty

## Brief/Intro

The current wasmvm@v2 exposes a risk surface area for DDOS of any contract or query implementing lists. The most prevalent queries that this applies to is the BankQuery::AllBalances

## Vulnerability Details

Per the conversation with Simon from Confio in the Cosmwasm Developers Discord,  A malicious actor can flood an contract (with or without ibc capabilities) with spam tokens (via neturons tokenfactory or an IBC token). This lead to a scenario where query gas limnits is reached before the total balances are returned, bricking functionality for contracts.

This also applies for IBC contracts, with Neturon (or any chain using cosmwasm@v2) as the counterparty chain. If a malicious actor has seeded the contract balance with hundreds or thousands of tokens, and if the IBC connection closes, any recovery logic implemented onChannelClose may be locked on Neturon due to Gas consumption limits.

## Impact Details

Any cosmwasm contract relying on AllBalances queries
Any IBC contracts (like abstract-accounts,polytone, and valence protocol) that have fund recovery logic during ibc-channel closure

## References

- Issue Conversation: <https://github.com/CosmWasm/cosmwasm/issues/2187>
- PR removing query support: <https://github.com/CosmWasm/cosmwasm/issues/2252>

## Proof of Concept

1. spin up two chains with tokenfactory,
2. spin up relayer & deploy polytone connection between to chains
3. simulate funding native BTC into counterparty contract (simulating accessing Neturoins prioritized bitcoin de-fi ecosystem)
4. mint 6900 unique tokens on the origin chain
5. IBC transfer all malicious tokens to counterparty contract
6. prevent relayer from upading client state, simulate connection close
7. verify that my BTC is trapped in contract state.