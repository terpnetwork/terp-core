# Mainnet Upgrade Guide: From Version $CURRENT_VERSION to $UPGRADE_VERSION

## Overview

This is a **coordinated, expedited** software upgrade. Validators **must** halt at
the upgrade height and restart with the `$UPGRADE_TAG` binary (Cosmovisor does
this automatically if the upgrade binary is pre-placed).

- **Plan name** (must match `app/upgrades`): `$UPGRADE_VERSION`
- **Git tag / binary**: `$UPGRADE_TAG`
- **$UPGRADE_VERSION proposal**: [Gov](https://www.ping.pub/terp/gov/$PROPOSAL_ID)
- **Upgrade height**: `$UPGRADE_BLOCK`
- **Countdown**: [Block countdown](https://www.ping.pub/terp/block/$UPGRADE_BLOCK)
- **Release**: [GitHub](https://github.com/terpnetwork/terp-core/releases/tag/$UPGRADE_TAG) · [S3](https://s3.terp.network/releases/terp-core/$UPGRADE_TAG/)

---

## Cosmovisor (recommended)

Cosmovisor swaps `terpd` at the on-chain plan name (`$UPGRADE_VERSION`). Docs:
[Cosmovisor](https://docs.cosmos.network/main/tooling/cosmovisor).

### Install (first time)

```sh
# SDK 0.50+ module path (do not use github.com/cosmos/cosmos-sdk/cosmovisor@v1.0.0)
go install cosmossdk.io/tools/cosmovisor/cmd/cosmovisor@v1.7.1

mkdir -p ~/.terpd/cosmovisor/genesis/bin
mkdir -p ~/.terpd/cosmovisor/upgrades

# Current (pre-upgrade) binary is genesis + current plan folder
cp "$(command -v terpd)" ~/.terpd/cosmovisor/genesis/bin/terpd
mkdir -p ~/.terpd/cosmovisor/upgrades/$CURRENT_VERSION/bin
cp "$(command -v terpd)" ~/.terpd/cosmovisor/upgrades/$CURRENT_VERSION/bin/terpd
```

```sh
export DAEMON_NAME=terpd
export DAEMON_HOME="$HOME/.terpd"
export DAEMON_ALLOW_DOWNLOAD_BINARIES=false
export DAEMON_RESTART_AFTER_UPGRADE=true
export DAEMON_POLL_INTERVAL=300ms
export UNSAFE_SKIP_BACKUP=true
# persist in ~/.profile as needed
```

Run the node **through** Cosmovisor, not raw `terpd start`:

```sh
cosmovisor run start
```

### Pre-place the $UPGRADE_VERSION binary (before halt)

Plan directory name **must** equal the on-chain upgrade name (`$UPGRADE_VERSION`, not the git tag).

```sh
mkdir -p ~/.terpd/cosmovisor/upgrades/$UPGRADE_VERSION/bin
# from source:
cd "$HOME/terp-core" && git fetch --tags && git checkout $UPGRADE_TAG && make build
cp build/terpd ~/.terpd/cosmovisor/upgrades/$UPGRADE_VERSION/bin/terpd
# or from S3 / GitHub release tarball, then:
# cp terpd ~/.terpd/cosmovisor/upgrades/$UPGRADE_VERSION/bin/terpd
chmod +x ~/.terpd/cosmovisor/upgrades/$UPGRADE_VERSION/bin/terpd
~/.terpd/cosmovisor/upgrades/$UPGRADE_VERSION/bin/terpd version
```

At height `$UPGRADE_BLOCK` Cosmovisor restarts into `$UPGRADE_VERSION` without a manual binary swap.

---

## Manual upgrade (no Cosmovisor)

1. Wait for height `$UPGRADE_BLOCK` and `UPGRADE "$UPGRADE_VERSION" NEEDED`.
2. Stop `terpd`.
3. Install `$UPGRADE_TAG` and start again:

```sh
cd "$HOME/terp-core"
git fetch --tags
git checkout $UPGRADE_TAG
make install
terpd start
```

---

## Binaries

| Platform | Artifact |
|----------|----------|
| linux/amd64 | [GitHub](https://github.com/terpnetwork/terp-core/releases/download/$UPGRADE_TAG/terpd-linux-amd64) · [S3 tarball](https://s3.terp.network/releases/terp-core/$UPGRADE_TAG/terpd-linux-amd64.tar.gz) |
| linux/arm64 | [GitHub](https://github.com/terpnetwork/terp-core/releases/download/$UPGRADE_TAG/terpd-linux-arm64) · [S3 tarball](https://s3.terp.network/releases/terp-core/$UPGRADE_TAG/terpd-linux-arm64.tar.gz) |

`make create-binaries-json RELEASE_TAG=$UPGRADE_TAG` emits Cosmovisor `upgrade-info` JSON.

---

## Additional resources

- Docs: https://docs.terp.network
- Discord: https://discord.gg/pAxjcFnAFH
