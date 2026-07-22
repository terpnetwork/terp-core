# Moved to terp-rs

All Private Bridge product libraries, pure seams, e2e harness, freezes, and docs
have been relocated out of the grant `spectrum/` tree into **terp-rs**.

| What | New home |
|------|----------|
| Pure seam crates | `crates/terp-rs/crates/{private_dex_seams,compose_seams,bridge_auth_seams,seam_note_out,cashapp_zec_corridor}` |
| Private DEX settle contract | `crates/terp-rs/contracts/revenue/private-dex` |
| Product docs, SPECs, freezes, USER-GUIDE | `crates/terp-rs/docs/private-bridge/` |
| E2E scripts / Zakura corridor | `crates/terp-rs/docs/private-bridge/e2e/` |
| Agent STATUS packs | `crates/terp-rs/docs/private-bridge/agents/` |
| mdBook | `crates/terp-rs/docs/private-bridge/book/` |

**Do not add new product SSOT here.** Grant archive material (if any remains) belongs under `docs/grant/`.

Entry points:

```bash
cd crates/terp-rs
cargo test -p private_dex_seams
cargo test -p compose_seams
# funded corridor (from headstash just, paths already retargeted):
cd ../headstash && just preflight-corridor-local && just demo-corridor-ict-egress-d
```
