# Mainnet Upgrade Guide: From Version v5 to v6

## Overview
- **v6 Upgrade Countdown**: [Block Countdown](https://testnet.ping.pub/terp/block/TBD)
---

### Upgrading to v6

*To prepare for the upgrade, execute these commands*:

```sh
mkdir -p ~/.terpd/cosmovisor/upgrades/v6/bin
cd $HOME/terp-core
git pull
git checkout v6.0.0
make build
cp build/terpd ~/.terpd/cosmovisor/upgrades/v6/bin
```

At the designated block height, Cosmovisor will automatically upgrade to version v6.

---

## Manual Upgrade Procedure

Follow these steps if you opt for a manual upgrade:

1. Monitor Terp Network until it reaches the specified upgrade block height: 69.
2. Observe for a panic message followed by continuous peer logs, then halt the daemon.
3. Perform these steps:

```sh
cd $HOME/terp-core
git pull
git checkout v6.0.0
make install
```

4. Restart the Terp-Core daemon and observe the upgrade.

---

## Additional Resources

- Terp Network Documentation: [Website](https://docs.terp.network)

### Initial Setup (For First-Time Users)

If you have not previously configured Cosmovisor, follow this section; otherwise, proceed to the next section.

Cosmovisor is strongly recommended for validators to minimize downtime during upgrades. It automates the binary replacement process according to on-chain `SoftwareUpgrade` proposals.

Documentation for Cosmovisor can be found [here](https://docs.cosmos.network/main/tooling/cosmovisor).

#### Installation Steps

*Run these commands to install and configure Cosmovisor*:

```sh
# go install github.com/cosmos/cosmos-sdk/cosmovisor/cmd/cosmovisor@v1.0.0
mkdir -p ~/.terpd
mkdir -p ~/.terpd/cosmovisor
mkdir -p ~/.terpd/cosmovisor/genesis
mkdir -p ~/.terpd/cosmovisor/genesis/bin
mkdir -p ~/.terpd/cosmovisor/upgrades
cp $GOPATH/bin/terpd ~/.terpd/cosmovisor/genesis/bin
mkdir -p ~/.terpd/cosmovisor/upgrades/v6/bin
cp $GOPATH/bin/terpd ~/.terpd/cosmovisor/upgrades/v6/bin
```

*Add these lines to your profile to set up environment variables*:

```sh
echo "# Cosmovisor Setup" >> ~/.profile
echo "export DAEMON_NAME=terpd" >> ~/.profile
echo "export DAEMON_HOME=$HOME/.terpd" >> ~/.profile
echo "export DAEMON_ALLOW_DOWNLOAD_BINARIES=false" >> ~/.profile
echo "export DAEMON_LOG_BUFFER_SIZE=512" >> ~/.profile
echo "export DAEMON_RESTART_AFTER_UPGRADE=true" >> ~/.profile
echo "export UNSAFE_SKIP_BACKUP=true" >> ~/.profile
source ~/.profile
```

### Upgrading to v6

*To prepare for the upgrade, execute these commands*:

```sh
mkdir -p ~/.terpd/cosmovisor/upgrades/v6/bin
cd $HOME/terp-core
git pull
git checkout v6.0.0
make build
cp build/terpd ~/.terpd/cosmovisor/upgrades/v6/bin
```

At the designated block height, Cosmovisor will automatically upgrade to version v6.

---

## Manual Upgrade Procedure

Follow these steps if you opt for a manual upgrade:

1. Monitor Terp Network until it reaches the specified upgrade block height: 69.
2. Observe for a panic message followed by continuous peer logs, then halt the daemon.
3. Perform these steps:

```sh
cd $HOME/terp-core
git pull
git checkout v6.0.0
make install
```

4. Restart the Terp-Core daemon and observe the upgrade.

---

## Additional Resources

- Terp Network Documentation: [Website](https://docs.terp.network)
- Community Support: [Discord](https://discord.gg/pAxjcFnAFH)
