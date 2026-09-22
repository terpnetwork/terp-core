# The ZK-CosmWasm Book

> **Active development.** This guide is under active development. Small invariants in accuracy—gas numbers, capability names, circuit paths, and ecosystem status—are still being identified and tuned. Prefer linked source code and upstream docs when you need production certainty.

Builder documentation for the **proof-verification CosmWasm** stack: host APIs, circuits, **cw-orch + ict-rs** test/deploy paths, then ecosystem light clients and applications.

## Parts

| Part | Focus |
|------|--------|
| **I — Using ZK-CosmWasm** | Proof VM · **Cw-Orch / ict-rs tooling** · reference |
| **II — Ecosystem** | Light clients · applications (vote-sdk, auth, bounties, demos) |
| **III — Community Program** | Thin public residual links (audit / hackathon) |

## Build Path

Start here when writing contracts or tests:

1. [Proof VM](using/vm/proof-vm.md)
2. [Architecture](using/vm/architecture.md)
3. [Circuits And Verifying Keys](using/vm/circuits.md)
4. [Cw-Orch Testing And Scripting](using/tooling/cw-orch.md) — circuits + Docker e2e

Then [Light Clients](using/ecosystem/light-clients/light-clients.md) / [Applications](using/ecosystem/applications/applications.md) as needed.
