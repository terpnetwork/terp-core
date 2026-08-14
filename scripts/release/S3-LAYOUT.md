# S3 / MinIO layout (canonical)

Host MinIO (alias `usb2`, public `https://s3.terp.network/`) uses **dedicated buckets**.
Software releases are **never** buried under `snapshots/`, and the first path segment
under `releases/` is always the **git repository name** — not a binary name.

## Buckets

| Bucket | Purpose |
|--------|---------|
| **`releases`** | Source (and optional binary) artifacts for **every project**, keyed by **repo name** |
| **`snapshots`** | Per-network chain ops: genesis, chain.json, entrypoint scripts, state archives |
| **`static`** | Websites / static assets |
| **`upgrades`** | Governance upgrade packages |

## `releases` bucket — one folder per repository

```
releases/
  <repo>/                    # git repository name ONLY (e.g. terp-core, o-line)
    <tag>/                   # semver or branch tag, e.g. v5.3.0-dev, v5.2.0
      manifest.json
      SOURCE_COMMIT
      source.tar.gz
      source.tar.gz.sha256
      docker-images.txt
      sha256sum.txt          # when binaries are published for this tag
      docker-build.env
      # optional binaries for that repo/tag (same folder, not a separate tree):
      #   terpd-linux-amd64.tar.gz, …
    latest/                  # optional pointer (manifest + digests only)
```

### Naming rules

| Do | Do not |
|----|--------|
| `releases/terp-core/v5.3.0-dev/` | `releases/v5.3.0-dev/` (bare tag) |
| `releases/terp-core/v5.2.0/` | `releases/terpd/…` (binary name) |
| `releases/o-line/<tag>/` | Mix network files into `releases/` |

**Rule:** top-level under `releases/` = **repository name**. Tags and binaries nest under that.

### Public URLs

```
https://s3.terp.network/releases/<repo>/<tag>/manifest.json
https://s3.terp.network/releases/<repo>/<tag>/source.tar.gz
https://s3.terp.network/releases/<repo>/latest/manifest.json
```

### Publish (terp-core)

```bash
make release-bundle RELEASE_TAG=v5.3.0-dev
make release-s3 RELEASE_TAG=v5.3.0-dev PROJECT=terp-core \
  NETWORK=testnet CHAIN_ID=120u-1 PUBLISH_LATEST=1
```

Env: `PROJECT` / `RELEASE_PROJECT` (default `terp-core`), `S3_BUCKET` (default `releases`).

## `snapshots` bucket — chain ops only

```
snapshots/
  <network>/                 # mainnet | testnet
    <chain_id>/              # morocco-1 | 120u-1
      genesis.json
      chain.json
      scripts/
        oline-entrypoint.sh
        config-node-endpoints.sh
        tls-setup.sh
      releases/
        <repo>/<tag>/        # lightweight pointer → software release for this chain
          manifest.json
          SOURCE_COMMIT
          source.tar.gz.sha256
          docker-images.txt
      *.tar.lz4              # state archives (optional)
```

| Question | Bucket |
|----------|--------|
| Where is verifiable source for repo X @ tag Y? | **`releases`** |
| How do I join network N? | **`snapshots`** |

## Docs

Website: [Public endpoints](https://docs.terp.network/docs/resources/public) (S3 bucket structure section).

## Migration notes

- Flat keys `releases/<tag>/` are removed after project-scoped publish (`MIGRATE_LEGACY_FLAT=1`).
- Binary-named trees (`releases/terpd/…`) are **not** allowed; delete them. Binaries belong under
  `releases/terp-core/<tag>/` if published at all.

## Container images

Binaries and manifests live on **S3**. Images live on the self-hosted registry:

```
containers.terp.network/terp-core:<tag>
```

Example: `docker pull containers.terp.network/terp-core:v6.0.0`

Do not publish operator-facing image pins to `ghcr.io/terpnetwork/terp-core`.
