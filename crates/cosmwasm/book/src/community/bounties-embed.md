# Dao Bounties Embed

Integrating a **DAO-scoped bounties UI embed**: parent application host + embed protocol, with optional native ZEC payment rails.

## Code locations

| Piece | Path / project |
|-------|----------------|
| Bounty platform (FE/API) | Monorepo `crates/zec-bounties/` (see that project’s README for ownership and setup) |
| Protocol notes | `crates/zec-bounties/docs/` (e.g. `protocol-terp-bounties-v1.md`, public-mode ship docs) |
| Broader DAO UI guides | DAO-DAO UI docs under the monorepo websites tree (wallet security, key-binding handoffs) |

## Developer concerns

1. **Embed protocol** — parent origin, message channel, which routes the embed may open.  
2. **Public DTOs** — list/detail responses should not leak nested email, cosmos addresses, or payout addresses unless selective disclosure is explicitly enabled.  
3. **Auth handshake** — ADR-036 (or related) signing for session establishment; see e2e scripts under `zec-bounties/scripts/`.  
4. **Payments** — ZEC-oriented flows depend on node/wallet tooling documented by that project (Zebrad / related stack).  
5. **Key-binding** — modular binding (e.g. ZIP-304-oriented designs) may land as iterative slices; track protocol freeze docs in-tree rather than inventing a parallel scheme.

## What belongs here vs community program

This page covers **how to embed and call APIs safely**, public DTO rules, and pointers to protocol freeze docs. Hackathon registration, prizes, and residual grant asks live under [Community](../../../community/overview.md).

## Minimal integration steps

1. Run or point at a bounties backend that implements the frozen public protocol version.  
2. Configure the parent app with the embed origin and allowed message types.  
3. Use **public-only** disclosure until you intentionally enable richer identity fields.  
4. Wire payout / bounty completion to your DAO’s on-chain modules as required by your deployment.  

For user-facing wallet security and DAO setup prose, prefer the published user guides linked from `zec-bounties/README.md` rather than duplicating them here.
