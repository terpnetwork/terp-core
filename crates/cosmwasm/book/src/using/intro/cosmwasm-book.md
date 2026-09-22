# Relationship To CosmWasm Book

| | CosmWasm Book | This book |
|--|---------------|-----------|
| Site | https://book.cosmwasm.com/ | https://zk.permissionless.money/ (when published) |
| Focus | Writing CosmWasm contracts | ZK-CosmWasm extensions, light clients, ecosystem applications |
| Upstream API docs | https://docs.cosmwasm.com/ | Plus engineering specs in this CosmWasm fork (`ZK_*.md`, `docs/*`) |

## Versioning note

This fork tracks CosmWasm packages with ZK extensions. Always check `Cargo.toml` versions in `packages/*` for the release you deploy; do not assume crates.io stock CosmWasm includes the ZK host import.
