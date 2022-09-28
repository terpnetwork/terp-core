#  Terp-Node Base Setup

## Hardware Requirements
* **Minimal**
    * 4 GB RAM
    * 100 GB SSD
    * 3.2 x4 GHz CPU
* **Recommended**
    * 8 GB RAM
    * 1 TB NVME SSD
    * 3.2 GHz x4 GHz CPU

## Operating System

* **Recommended**
    * Linux(x86_64)


## Installation Steps
#### 1. Basic Packages
```bash:
# update the local package list and install any available upgrades 
sudo apt-get update && sudo apt upgrade -y 
# install toolchain and ensure accurate time synchronization 
sudo apt-get install make build-essential gcc git jq chrony -y
```
```bash:
# install gcc & make
sudo apt install gcc && sudo apt install make
```

#### 2. Install Go
Follow the instructions [here](https://golang.org/doc/install) to install Go.

Alternatively, for Ubuntu LTS, you can do:
```bash:
wget https://go.dev/dl/go1.19.1.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.19.1.linux-amd64.tar.gz
```

Unless you want to configure in a non standard way, then set these in the `.profile` in the user's home (i.e. `~/`) folder.

```bash:
cat <<EOF >> ~/.profile
export GOROOT=/usr/local/go
export GOPATH=$HOME/go
export GO111MODULE=on
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin
EOF
source ~/.profile
go version
```

Output should be: `go version go1.19.1 linux/amd64`

<a id="install-terpd"></a>
### Install terpd from source

#### 1. Clone repository

* Clone git repository
```shell
git clone https://github.com/terpnetwork/terp-core.git
```
* Checkout latest tag
```shell
cd terp-core
git fetch --tags
git checkout v0.1.0
```
#### 2. Install CLI
```shell
make build && make install
```

To confirm that the installation was successful, you can run:

```bash:
terpd version
```
Output should be: `v0.1.0`

## Instruction for new validators

### Init
```bash:
terpd init "$MONIKER_NAME" --chain-id $CHAIN_ID
```

### Generate keys

```bash:
# To create new keypair - make sure you save the mnemonics!
terpd keys add <key-name> 
```

or
```
# Restore existing terp wallet with mnemonic seed phrase. 
# You will be prompted to enter mnemonic seed. 
terpd keys add <key-name> --recover
```
or
```
# Add keys using ledger
terpd keys show <key-name> --ledger
```

Check your key:
```
# Query the keystore for your public address 
terpd keys show <key-name> -a
```

## Validator Setup Instructions

### Download new genesis file
```bash:
curl https://raw.githubusercontent.com/terpnetwork/test-net/master/athena-1/genesis.json > ~/.terp/config/genesis.json
```
### Set minimum gas fees
```bash:
perl -i -pe 's/^minimum-gas-prices = .+?$/minimum-gas-prices = "0.0125upersyx"/' ~/.terp/config/app.toml
```
### P2P

#### Add seeds
```bash:
TBD
```
### Add persistent peers
```bash:
7e5c0b9384a1b9636f1c670d5dc91ba4721ab1ca@23.88.53.28:36656
```
### OR

### Download addrbook.json
```bash:
TBD
```

### Setup Unit/Daemon file

```bash:
# 1. create daemon file
touch /etc/systemd/system/terpd.service
# 2. run:
cat <<EOF >> /etc/systemd/system/terpd.service
[Unit]
Description=Terp Net daemon
After=network-online.target
[Service]
User=<USER>
ExecStart=/home/<USER>/go/bin/terpd start
Restart=on-failure
RestartSec=3
LimitNOFILE=4096
[Install]
WantedBy=multi-user.target
EOF
# 3. reload the daemon
systemctl daemon-reload
# 4. enable service - this means the service will start up 
# automatically after a system reboot
systemctl enable terpd.service
# 5. start daemon
systemctl start terpd.service
```

In order to watch the service run, you can do the following:
```
journalctl -u terpd.service -f
```

Congratulations! You now have a full node. Once the node is synced with the network, 
you can then make your node a validator.

### Create validator
1. Transfer funds to your validator address. A minimum of 1  (1000000uterpx) is required to start a validator.

2. Confirm your address has the funds.

```
terpd q bank balances $(terpd keys show -a <key-alias>)
```

3. Run the create-validator transaction
**Note: 1,000,000 uterpx = 1 , so this validator will start with 1 **

```bash:
terpd tx staking create-validator \ 
--amount 1000000uterpx \ 
--commission-max-change-rate "0.05" \ 
--commission-max-rate "0.10" \ 
--commission-rate "0.05" \ 
--min-self-delegation "1" \ 
--details "validators write bios too" \ 
--pubkey $(terpd tendermint show-validator) \ 
--moniker $MONIKER_NAME \ 
--chain-id $CHAIN_ID \ 
--fees 2000upersyx \
--from <key-name>
```

To ensure your validator is active, run:
```
terpd q staking validators | grep moniker
```

### Backup critical files
```bash:
priv_validator_key.json
node_key.json
```

## Instruction for old validators

### Stop node
```bash:
systemctl stop terpd.service
```

### Install latest Terpd from source [TODO: Update for v0.x.0]

[Install latest Terpd](#install-terpd)

### Download genesis file
```bash:
curl https://raw.githubusercontent.com/terpnetwork/net/main/mainnet/genesis.json > ~/.terp/config/genesis.json
```

### Clean old state

```bash:
terpd tendermint unsafe-reset-all --home ~/.terp
```

### Rerun node
```bash:
systemctl daemon-reload
systemctl start terpd.service
```
