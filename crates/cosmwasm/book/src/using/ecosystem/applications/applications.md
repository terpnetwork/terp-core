# Applications

**Applications** are ecosystem libraries and product surfaces that sit **above** the proof VM and light clients: voting, smart-account authentication, DAO bounties embeds, and demos.

This is **not** core VM architecture. It is the **application layer**—expected to grow as support expands beyond a single privacy stack.

```
┌────────────────────────────────────────────┐
│  Product UIs / DAO tools / demos           │  ← Applications
├────────────────────────────────────────────┤
│  Vote-Sdk · Smart-Account Auth · Bounties  │
├────────────────────────────────────────────┤
│  Light clients (tip / finality)            │  ← Light Clients
├────────────────────────────────────────────┤
│  Proof VM (circuit verify host)            │  ← Proof VM
└────────────────────────────────────────────┘
```

| Surface | Role |
|---------|------|
| [Vote-Sdk](./vote-sdk.md) | Commitments, eligibility, vote circuits ([valargroup/vote-sdk](https://github.com/valargroup/vote-sdk)) |
| [Smart-Account Authenticators](./smart-account-auth.md) | `x/smart-account` + `TerpAccountTrait` suite ([terp-rs](https://github.com/permissionlessweb/terp-rs)) |
| [Dao Bounties Embed](./bounties-embed.md) | DAO-scoped board embed for integrators |
| [Demo Map](./demo-overview.md) / [Public Verify](./demo-public-verify.md) | Reproducible developer demos |

Community program (audit, hackathon registration): [Community](../../../community/overview.md).
