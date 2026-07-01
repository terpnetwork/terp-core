# 90u-2 relaunch

The following document describes the necessary steps involved that full-node operators
must take in order to restart their nodes for 90u-2.

The genesis state of `90u-2` has been derived from the export of the previous test network, and will include a fresh batch of gentxs, as the previous test network has become stale. 

## Overview

### I. Validation SubDAO Consensus 

First, a [DAO proposal](https://daodao.zone/dao/juno1wpq03vzv4f9fczss0sqt4xxfmxel6zmhdxal68lg8qpa7cgzj25sy3k3dt/) including the PR containing the specifics regarding the 90u-2 test-net relaunch will be proposed. This includes:

- Steps taken to generate the new genesis file (Details are found in [Export Migration](./docs/export-migration.md))
- The relaunch timeline, including the gentx submission.

The proposal can be found [here.](./docs/proposal.md)

### II. Relaunch modification, or Gentx Submissions

If the consensus is to **reject** the proposed details, modifications in the details may be taken, & a reproposal can be made. 

If the consensus is to **accept** the proposed details, they can be used as a guideline for participation in the next steps. 

### III. Network Launch

Node setup instructions, & Peer endpoints can be available for anyone to participate in the relaunch of the test network in  [Terp Network's Chain-Registry Fork](https://github.com/terpnetwork/chain-registry).

## Genesis File 
To download the genesis file to your initalized node:
```
curl -s https://raw.githubusercontent.com/terpnetwork/test-net/master/90u-2/genesis.json > $HOME/.terp/config/genesis.json
```
#### Checking validity of genesis file
To verify the authenticity of the genesis file:
```
sha256sum $HOME/.terp/config/genesis.json 
```
should return `5e7bc1d51e1a12318ed49ba90b03f76680af8d8ccc4f113b8179860849941a05`

## P2P info

### Seed node

#### create a shell variable for the seeds 
```
export SEEDS="74d89379b11badacff139e57b553202072a162c1@173.230.130.51:26656"
```
#### check that the shell variable is set up properly
```
echo $SEEDS
```

#### add seed to config.toml
```
sed -i.bak -e "s/^seeds *=.*/seeds = \"$SEEDS\"/" ~/.terp/config/config.toml
```

### Persistent Peers

#### create a shell variable for the persistent peers
```
export PEERS="3e5e25f10a7bf3467fcb24ed59124b5e00ab3d0b@136.243.136.241:32656,79ba637ef59c94ba41c870806903b4e907594f32@65.109.174.30:26656"
```
#### check that the shell variable is set up properly
```
echo $PEERS
```
#### add peers to config.toml
```
sed -i.bak -e "s/^persistent_peers *=.*/persistent_peers = \"$PEERS\"/" ~/.terp/config/config.toml
```