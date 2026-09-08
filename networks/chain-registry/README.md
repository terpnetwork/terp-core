# Chain registry (SoT)

This tree is the **only** in-repo copy of the Terp chain-registry draft.

Path: `networks/chain-registry/terpnetwork/`

Upstream `cosmos/chain-registry/terpnetwork` is updated by PR **after** a
release is public on our hosts. Do not add a second copy at repo root,
under `docs/`, or under `networks/upgrades/*/`.

## Where operators fetch artifacts

| Kind | Host |
|------|------|
| Source, checksums, binaries, manifests | `https://s3.terp.network/releases/terp-core/<tag>/` |
| Container images | `registry.terp.network/terp-core:<tag>` |

Sequence (morocco-1):

| step | version | halt | artifacts |
|------|---------|------|-----------|
| now (rolling patch) | **v6.0.1** | none | `releases/terp-core/v6.0.1/` + `registry.terp.network/terp-core:v6.0.1` (linux amd64) |
| gov plan `v6.1` (proposal 59) | **v6.1.0** | **23191300** | `releases/terp-core/v6.1.0/` |
| handler arms `v6.2` at apply+2 | **v6.2.0** | **23191302** | `releases/terp-core/v6.2.0/` |

`chain.json` `recommended_version` is **v6.0.1** until the v6.1 halt. Do not run v6.1.0 / v6.2.0 before height 23191300.

Example:

```
https://s3.terp.network/releases/terp-core/v6.0.1/sha256sum.txt
https://s3.terp.network/releases/terp-core/v6.0.1/terpd-6.0.1-linux-amd64.tar.gz
registry.terp.network/terp-core:v6.0.1
```
