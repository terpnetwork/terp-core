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
| Container images | `containers.terp.network/terp-core:<tag>` |

Example:

```
https://s3.terp.network/releases/terp-core/v6.0.0/manifest.json
https://s3.terp.network/releases/terp-core/v6.0.0/terpd-6.0.0-linux-amd64.tar.gz
containers.terp.network/terp-core:v6.0.0
```

`recommended_version` stays on **v5.2.0** until v6 is tagged and the halt succeeds.
