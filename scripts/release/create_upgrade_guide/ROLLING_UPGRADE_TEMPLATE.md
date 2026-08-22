# Rolling Upgrade Guide: From Version $CURRENT_VERSION to $UPGRADE_VERSION

## Overview

This is a **non-breaking rolling upgrade**. No governance proposal is required.
Validators should upgrade at their earliest convenience.

- **Upgrade version**: $UPGRADE_VERSION
- **Upgrade tag**: $UPGRADE_TAG
- **Release**: [GitHub](https://github.com/terpnetwork/terp-core/releases/tag/$UPGRADE_TAG) · [S3](https://s3.terp.network/releases/terp-core/$UPGRADE_TAG/)

## Binary downloads

| Platform | Architecture | Download |
|----------|-------------|----------|
| Linux    | amd64       | [GitHub](https://github.com/terpnetwork/terp-core/releases/download/$UPGRADE_TAG/terpd-linux-amd64) · [S3](https://s3.terp.network/releases/terp-core/$UPGRADE_TAG/terpd-linux-amd64.tar.gz) |
| Linux    | arm64       | [GitHub](https://github.com/terpnetwork/terp-core/releases/download/$UPGRADE_TAG/terpd-linux-arm64) · [S3](https://s3.terp.network/releases/terp-core/$UPGRADE_TAG/terpd-linux-arm64.tar.gz) |

## Upgrade steps

### Option 1: Build from source

```sh
cd "$HOME/terp-core"
git fetch --tags
git checkout $UPGRADE_TAG
make install
```

Restart `terpd`.

### Option 2: Pre-built binary

```sh
wget https://github.com/terpnetwork/terp-core/releases/download/$UPGRADE_TAG/terpd-linux-amd64 -O terpd
chmod +x terpd
sudo mv terpd /usr/local/bin/
```

### Option 3: Cosmovisor

```sh
go install cosmossdk.io/tools/cosmovisor/cmd/cosmovisor@v1.7.1
mkdir -p ~/.terpd/cosmovisor/upgrades/$UPGRADE_VERSION/bin
cd "$HOME/terp-core" && git fetch --tags && git checkout $UPGRADE_TAG && make build
cp build/terpd ~/.terpd/cosmovisor/upgrades/$UPGRADE_VERSION/bin/terpd
```

Folder name `$UPGRADE_VERSION` must match the on-chain plan name if this later becomes a coordinated halt.

## Verification

```sh
terpd version
```

Expected: `$UPGRADE_TAG`.

---

## Additional resources

- Docs: https://docs.terp.network
- Discord: https://discord.gg/pAxjcFnAFH
