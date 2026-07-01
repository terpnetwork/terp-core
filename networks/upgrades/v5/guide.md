# Terp-Core v5 - Eudesmol Upgrade

|                 |                                                              |
|-----------------|--------------------------------------------------------------|
| Chain-id        | `morocco-1`                                                  |
| Upgrade Version | [`v5`](https://github.com/terpnetwork/terp-core/releases/tag/v5.0.0)                                                  |
| Upgrade Height  | [`14170662`](https://ping.pub/terp/block/14170662)                                                    |

The target block for this upgrade is `14170662`, which is expected to arrive at 11:00UTC Monday, September 30th ~ 1 PM UTC [Go Playground](hthttps://go.dev/play/p/cyxyYqhGtRp)

## PRE-UPGRADE-SCRIPT

> VALIDATORS MUST MODIFY THEIR `CONFIG.TOML` CONSENSUS PARAMETERS **AFTER** REACHING THE COORDINATED HALT HEIGHT, & BEFORE **INSTALLING** THE NEWEST VERSION OF TERP-CORE

This can be done 1 of 3 ways:

1. **Manually**: Nodes not using cosmovisor will **wait until the network halts**, then **manually apply `config.toml` changes** before installing the v5.0.0 binary and restarting.
2. **With Default Cosmovisor**: Node operators must download the pre-upgrade script and set environment variables BEFORE reaching our coordinated halt height. Cosmovisor will automatically execute the script and upgrade when the halt height is reached.
3. **With Custom Cosmovisor**: A modified cosmovisor that automatically downloads and executes pre-upgrade scripts. Operators must install the custom cosmovisor binary BEFORE reaching the coordinated halt height - no manual script download required.

### A. WITHOUT COSMOVISOR: Manual Update to `config.toml`  

Upon reaching the coordinated halt height, apply the changes needed to your config files BEFORE installing the latest version:

```sh
# define your nodes config file location
export CONFIG_PATH=$HOME/.terp/config/config.toml
# apply updates to the consensus params
sed -i.bak "/^\[consensus\]/,/^\[/ s/^[[:space:]]*timeout_commit[[:space:]]*=.*/timeout_commit = \"2400ms\"/" "$CONFIG_PATH"
sed -i.bak "/^\[consensus\]/,/^\[/ s/^[[:space:]]*timeout_propose[[:space:]]*=.*/timeout_propose = \"2400ms\"/" "$CONFIG_PATH"
# confirm updates were applied
grep -E "timeout_commit|timeout_propose" "$CONFIG_PATH"
# should see:
# timeout_propose = "2400ms"
# # How much timeout_propose increases with each round
# timeout_propose_delta = "500ms"
# timeout_commit = "2400ms"
# skip_timeout_commit = false
```

### B. WITH COSMOVISOR: Semi-Automatic Upgrade Via Cosmovisor

Cosmovisor support the execution of a pre-upgrade script, if one exists in the expected location within cosmovisors home directory. You can prepare your cosmovisor to execute the pre-upgrade-script via the following steps:

```sh
systemctl stop terpd.service
# download & verify the sh script, place in the correct location for cosmovisor
wget https://raw.githubusercontent.com/terpnetwork/networks/refs/heads/main/mainnet/upgrades/v5/preUpgradeScript.sh $DAEMON_HOME/cosmovisor/preUpgradeScript.sh
# confirm checksums match 
sha256sum preUpgradeScript.sh $DAEMON_HOME/cosmovisor/preUpgradeScript.sh
# output should be: 
# b0e25f094b20d62925d5bcb1f8850d06ccfb5874f70db8855723ea02bf96e4fc  preUpgradeScript.sh
# set the environment variable for cosmovisor (preferably in systemd file)
sudo sed -i '' 's/Environment="DAEMON_RESTART_AFTER_UPGRADE=true"/&\'$'\n''Environment="COSMOVISOR_CUSTOM_PREUPGRADE=preUpgradeScript.sh"/' /etc/systemd/system/terpd.service
# reload the daemon-process
sudo -S systemctl daemon-reload
sudo systemctl start terpd
```

Cosmovisor will now perform the pre-upgrade scripts one reaching the coordinated halt height & prior to installing and resuming with the latest terp-core version.

### C. WITH CUSTOM COSMOVISOR: Fully-Automatic Upgrade Via Custom Cosmovisor
>
> If you would like to completely automate the pre-upgrade script, **we have released a version of cosmovisor** that will download any preUpgradeScript defined in the UpgradeInfo embedded in our upgrade proposal. You can review the modifications made [here](https://github.com/permissionlessweb/cosmos-sdk/compare/648633cc6d1eac408c87ad892f237cebd1ecc549...af61af47e79fd807559ec3148f5a0bea8ea749e9).

**If you ARE already running cosmovisor**, before reaching the coordinated upgrade height:

```sh
# kill existing cosmovisor process
systemctl stop terpd.service
# build/install custom cosmovisor
git clone -b feat/cosmovisor-preupgradescript https://github.com/permissionlessweb/cosmos-sdk cv-cosmos-sdk
cd cv-cosmos-sdk/tools/cosmovisor || exit
make cosmovisor
sudo mv cosmovisor /usr/local/bin/
# resume cosmovisor process
sudo -S systemctl daemon-reload
sudo systemctl start terpd
```

**If you ARE NOT running cosmovisor**, berfore reaching the coordinated upgrade height:

```sh
# kill any terpd process
systemctl stop terpd.service
# install custom cosmovisor version 
git clone -b feat/cosmovisor-preupgradescript https://github.com/permissionlessweb/cosmos-sdk cv-cosmos-sdk
# traverse into cosmovisor root
cd cv-cosmos-sdk/tools/cosmovisor || exit
# build cosmovisor image manually
make cosmovisor
# move binary into system-wide user binary directory
mv cosmovisor /usr/local/bin/
# cleanup workspace
cd ../../../ && rm -rf cv-cosmos-sdk
# initialize and configure
#
# define environment variables
export DAEMON_NAME=terpd
export DAEMON_HOME=$HOME/.terp
# move existing binary into path cosmovisor accesses
cosmovisor init $HOME/go/bin/terpd
# setup systemd process
sudo bash -c 'cat > /etc/systemd/system/terpd.service << EOF
[Unit]
Description=terpd Daemon (cosmovisor)
After=network-online.target

[Service]
User='$USER'
ExecStart=/home/'$USER'/go/bin/cosmovisor run start
Restart=always
RestartSec=3
LimitNOFILE=4096
Environment=DAEMON_NAME='terpd'
Environment=DAEMON_HOME='$HOME/.terp'
Environment="DAEMON_ALLOW_DOWNLOAD_BINARIES=true"
Environment="DAEMON_RESTART_AFTER_UPGRADE=true"

[Install]
WantedBy=multi-user.target
EOF'

# reload systemctl 
sudo -S systemctl daemon-reload
sudo -S systemctl enable terpd
# enable
sudo systemctl start terpd
```

Now, when cosmovisor recieves an upgrade plan, it will download & prepare the pre-upgrade script, if it exists, automatically.

## Building Manually

```sh
cd terp-core
cd terp-core && git pull && git checkout v5.0.0
make build && make install 

terpd version --long | grep "cosmos_sdk_veresion/|commit\|version:"
# commit:  1620a3086cef50a3e3acb592469b0ebad3981a3e
# cosmos_sdk_version: v0.53.4
# version: 5.0.0

mkdir -P $DAEMON_HOME/cosmovisor/upgrades/v5/bin && cp $HOME/go/bin/terpd $DAEMON_HOME/cosmovisor/upgrades/v5/bin 

$DAEMON_HOME/cosmovisor/upgrades/v5/bin/terpd version
```

## Downloading Precompiled Build

```sh
rm -rf terpd_linux_amd64.tar.gz # delete if exists
wget https://github.com/terpnetwork/terp-core/releases/download/v5.0.0/terpd-linux-amd64.tar.gz
sha256sum terpd-linux-amd64.tar.gz
# Output  768b281a522bdff2781cc7c11177f756f44526e6e3388e8febb8a347481d0870 terpd-linux-amd64.tar.gz
```
