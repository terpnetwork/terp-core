# Smart-Account Authenticators

This stack’s product focus is **complementing the chain smart-account module** with CosmWasm **authenticator contracts** that plug into the module’s authentication workflow.

## Two layers that work together

| Layer | What it is | Role |
|-------|------------|------|
| **`x/smart-account` (chain module)** | Cosmos SDK ante / post handlers, circuit breaker, selected authenticators, fee collection, track + confirm | Owns *when* authenticators run in the tx pipeline |
| **`TerpAccountTrait` + contract suite (terp-rs)** | CosmWasm contracts implementing module-driven sudo hooks | Curates *how* messages are authenticated (passkey, curves, ZK claims, etc.) |

Optional helper crates (credential formatting, envelopes, client-side request helpers) such as [smart-account-auth](https://github.com/permissionlessweb/terp-rs) can be used by those contracts and by wallets. **They are libraries curated by their maintainers**; this book’s emphasis is the module + trait workflow and the authenticator suite that implements it.

## Module workflow (what the chain expects)

Terp’s `x/smart-account` follows the Osmosis-style authenticator pipeline (see module README in the Terp monorepo):

1. **Circuit breaker** — module can fall back to classic SDK auth when disabled or when no authenticators are selected.  
2. **Per-message `Authenticate`** — selected authenticator validates the message (stateless preferrence for the auth step).  
3. **`Track`** — after all messages authenticate, authenticators may record stateful side effects that **persist even if later execution fails**.  
4. **Execute messages**  
5. **`ConfirmExecution`** — post-exec rules (spend limits, etc.); failure can revert execution changes.

CosmWasm authenticators are invoked as **sudo** messages from the module (`AuthSudoMsg` / `AuthenticationRequest`, add/remove hooks, track, confirm).

## Contract design: `TerpAccountTrait`

Implementors live in **terp-rs** and implement `terp_auth::TerpAccountTrait` (legacy alias: `BtsgAccountTrait`):

| Hook | Purpose in the module workflow |
|------|--------------------------------|
| `process_sudo_auth` | Route all module sudo entrypoints |
| `on_auth_added` / `on_auth_removed` | Validate config and lifecycle on `MsgAddAuthenticator` / remove |
| `on_auth_request` | **Stateless** authenticate / reject (no durable state updates) |
| `on_auth_track` | Stateful notify after successful auth (committed even if exec fails) |
| `on_auth_confirm` | Post-execution policy |
| `extended_authenticate` / `on_hooks` | Optional helpers outside the default path |

Canonical sources:

| Surface | Link |
|---------|------|
| Trait + types | https://github.com/permissionlessweb/terp-rs (`crates/terp-auth`) |
| Authenticator contracts | https://github.com/permissionlessweb/terp-rs/tree/v0.0.2-dev/contracts/smart-accounts |
| Suite (cw-orch deploy + mock matrix) | `terp-authenticator-suite` in the same tree |
| Chain module | Terp monorepo `x/smart-account` (module SoT for ante/post semantics) |
| Credential library (optional) | https://github.com/permissionlessweb/terp-rs — curated by that project’s maintainers |

## Suite members (representative)

| Crate / surface | Notes |
|-----------------|--------|
| `terp-passkey` | Passkey / WebAuthn turnstile |
| `terp-ed25519`, `terp-eth` | Classic curve signers |
| `terp-zkjwt` | JWT-style claims (often with host ZK when `zk-host` tests apply) |
| `terp-zkpallas` | Multi-curve / vote-oriented digests and host routing |
| `terp-vsck` | Vote-sdk-oriented private voting auth |
| `terp-authenticator-suite` | Shared deploy/test helpers |

## Composition with ZK-CosmWasm

- Authenticator contracts gate execute with classical credentials **or** host-verified proofs.  
- **`proof_instance_verify`** covers ZK statements (membership, eligibility, vote validity) when the chain’s wasmvm exports the host import.  
- Products often compose both: session turnstile + periodic ZK eligibility.

These crates do not replace the proof VM; they are the **smart-account turnstile layer** wired to `x/smart-account`.

## Deploy and tests

See the suite README and `TESTS_README.md` under `terp-authenticator-suite` in [terp-rs](https://github.com/permissionlessweb/terp-rs) for green paths vs residual public testnet work. Deploy helpers live under `terp-scripts` in that repo.
