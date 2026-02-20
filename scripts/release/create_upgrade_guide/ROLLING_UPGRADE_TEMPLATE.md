# Rolling Upgrade Guide: From Version $CURRENT_VERSION to $UPGRADE_VERSION

## Overview

This is a **non-breaking rolling upgrade**. No governance proposal is required. Validators are reccomended to upgarde at their earliest convenience.

- **Upgrade Version**: $UPGRADE_VERSION
- **Upgrade Tag**: $UPGRADE_TAG
- **Release**: [GitHub Release](https://github.com/terpnetwork/terp-core/releases/tag/$UPGRADE_TAG)

## Binary Downloads

Pre-built binaries are available on the [release page](https://github.com/terpnetwork/terp-core/releases/tag/$UPGRADE_TAG):

| Platform | Architecture | Download |
|----------|-------------|----------|
| Linux    | amd64       | [terpd-linux-amd64](https://github.com/terpnetwork/terp-core/releases/download/$UPGRADE_TAG/terpd-linux-amd64) |
| Linux    | arm64       | [terpd-linux-arm64](https://github.com/terpnetwork/terp-core/releases/download/$UPGRADE_TAG/terpd-linux-arm64) |

## Upgrade Steps

### Option 1: Build from Source

```sh
cd $HOME/terp-core
git pull
git checkout $UPGRADE_TAG
make install
```

Restart the terpd daemon after building.

### Option 2: Download Pre-built Binary

```sh
# For amd64:
wget https://github.com/terpnetwork/terp-core/releases/download/$UPGRADE_TAG/terpd-linux-amd64 -O terpd
chmod +x terpd
sudo mv terpd /usr/local/bin/

# For arm64:
wget https://github.com/terpnetwork/terp-core/releases/download/$UPGRADE_TAG/terpd-linux-arm64 -O terpd
chmod +x terpd
sudo mv terpd /usr/local/bin/
```

Restart the terpd daemon after replacing the binary.

### Option 3: Cosmovisor

If you use Cosmovisor, place the new binary in the upgrades directory:

```sh
mkdir -p ~/.terpd/cosmovisor/upgrades/$UPGRADE_VERSION/bin
cd $HOME/terp-core
git pull
git checkout $UPGRADE_TAG
make build
cp build/terpd ~/.terpd/cosmovisor/upgrades/$UPGRADE_VERSION/bin
```

## Verification

After upgrading, verify the version:

```sh
terpd version
```

Expected output should include version `$UPGRADE_TAG`.

---

## Additional Resources

- Terp Network Documentation: [Website](https://docs.terp.network)
- Community Support: [Discord](https://discord.gg/pAxjcFnAFH)
