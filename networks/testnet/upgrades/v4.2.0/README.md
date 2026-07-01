# Upgrade Terp Network from v4.1.1 to v4.2.0

This upgrade follows the state export the network, so that we are using the same terpd version on the testnet as the mainnet. 

### Release Details
* Go version has been frozen at `1.21`. If you are going to build `terpd` binary from source, make sure you are using the right GO version!

## Halt height 
This upgrade requires `terpd` halting execution at a pre-selected halt-height. Failing to stop at halt-height may cause a consensus failure during chain execution at a later time.

There are two mutually exclusive options for this stage:

### Option 1: Set the halt height by modifying app.toml
- Stop the terpd process.
- Edit the application configuration file at `~/.terp/config/app.toml` so that halt-height reflects the upgrade plan:
```yaml
# Note: Commitment of state will be attempted on the corresponding block.
halt-height = 3686838
```
- restart terpd process
- Wait for the upgrade height and confirm that the node has halted

### Option 2: Restart the terpd binary with command line flags
- Stop the terpd process.
- Do not modify `app.toml`. Restart the terpd process with the flag `--halt-height`:
```
terpd start --halt-height 3686838
```
- Wait for the upgrade height and confirm that the node has halted

Upon reaching the halt-height you need to replace the `v4.2.0`terpd binary with the new terpd `v4.2.0` binary and remove the halt-height constraint. Depending on your setup, you may need to set halt-height = 0 in your app.toml before resuming operations.

### Exported state 

The snapshot of the state will be taken at block height [3686837](https://testnet.itrocket.net/terp/block/3686837), one block before the halt height, by the following command:
```sh
terpd export --height 3686837 --for-zero-height --output-document 90u-3.json
```

# Performing the co-ordinated upgrade

This co-ordinated upgrades requires validators to stop their validators, remove all data from the node, download the new genesis file, and restart the node service.
The exact sequence of steps depends on your configuration. Please take care to modify your configuration appropriately if your setup is not included in the instructions.

# Manual steps
## Step 1: Backup previous state, restart the node.

backup local node directory
```sh
sudo cp -r $HOME/.terp $HOME/.terp.backup
```

reset local node directory
```sh 
terpd tendermint unsafe-reset-all --home $HOME/.terp 
```
download the new genesis file 
```sh
wget -O $HOME/.terp/config/genesis.json https://raw.githubusercontent.com/hard-nett/networks/90u-3/testnet/90u-3/genesis.json
```

configure new peers 
```sh
SEEDS="e3f7a6a37f9b1bc7648603360b24312493c031f1@testnet-peer.terp.network:26656"
PEERS="e3f7a6a37f9b1bc7648603360b24312493c031f1@testnet-peer.terp.network:26656"
sed -i -e "s/^seeds *=.*/seeds = \"$SEEDS\"/; s/^persistent_peers *=.*/persistent_peers = \"$PEERS\"/" $HOME/.terp/config/config.toml
```

### Build and start the binary

```shell
cd $HOME/terp-core
git fetch --all 
git checkout main 
make install

# verify install
terpd version
# v4.2.0
```

start the new network node
```shell
terpd start # starts the v4.2.0 node
```

if all is well, remove the backup state 
```shell
rm -rf $HOME/.terp.backup
```