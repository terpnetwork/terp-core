# Upgrade Terp Network from v4.1.1 to v4.2.0

## This is a security upgrade. IT IS CONSENSUS BREAKING, so please apply the fix only on height TBD.

### Release Details
* https://github.com/terpnetwork/terp-core/releases/tag/v4.2.0 
* Chain upgrade height : `5486131`. Exact upgrade time can be checked [here](https://ping.pub/terp/block/5486131).
* Go version has been frozen at `1.21`. If you are going to build `terpd` binary from source, make sure you are using the right GO version!

# Performing the co-ordinated upgrade

This co-ordinated upgrades requires validators to stop their validators at `5486131`, switch their binary to `v4.2.0` and restart their nodes with the new version.

The exact sequence of steps depends on your configuration. Please take care to modify your configuration appropriately if your setup is not included in the instructions.

# Manual steps

## Step 1: Configure `halt-height` and restart the node.

This upgrade requires `terpd` halting execution at a pre-selected `halt-height`. Failing to stop at `halt-height` may cause a consensus failure during chain execution at a later time.

There are two mutually exclusive options for this stage:

### Option 1: Set the halt height by modifying `app.toml`

* Stop the terpd process.

* Edit the application configuration file at `~/.terp/config/app.toml` so that `halt-height` reflects the upgrade plan:

```toml
# Note: Commitment of state will be attempted on the corresponding block.
halt-height = 5486131
```
* restart terpd process

* Wait for the upgrade height and confirm that the node has halted

### Option 2: Restart the `terpd` binary with command line flags

* Stop the terpd process.

* Do not modify `app.toml`. Restart the `terpd` process with the flag `--halt-height`:
```shell
terpd start --halt-height 5486131
```

* Wait for the upgrade height and confirm that the node has halted

Upon reaching the `halt-height` you need to replace the `v4.1.1` terpd binary with the new `terpd v4.2.0` binary and remove the `halt-height` constraint.
Depending on your setup, you may need to set `halt-height = 0` in your `app.toml` before resuming operations.
```shell
   git clone https://github.com/terpnetwork/terp-core.git
```

### Build and start the binary

```shell
cd $HOME/terp-core
git pull
git fetch --tags
git checkout main
make install

# verify install
terpd version
# v4.2.0
```

```shell
terpd start # starts the v4.2.0 node
```

## Cosmovisor steps

### Prerequisite: Alter systemd service configuration

Disable automatic restart of the node service. To do so please alter your `terpd.service` file configuration and set appropriate lines to following values.

```
Restart=no 

Environment="DAEMON_ALLOW_DOWNLOAD_BINARIES=false"
Environment="DAEMON_RESTART_AFTER_UPGRADE=false"
```

After that you will need to run `sudo systemctl daemon-reload` to apply changes in the service configuration.

There is no need to restart the node yet; these changes will get applied during the node restart in the next step.

# Setup Cosmovisor
## Create the updated terpd binary of v4.2.0

### Go to terpd directory if present else clone the repository

```shell
   git clone https://github.com/terpnetwork/terp-core.git
```

### Follow these steps if terpd repo already present

```shell
   cd $HOME/.terp
   git pull
   git fetch --tags
   git checkout v4.2.0
   make install
```

### Check the new terpd version, verify the latest commit hash
```shell
   $ terpd version --long
   name: terpd
   server_name: terpd
   version: 4.2.0
   commit: <commit-hash>
   ...
```

### Or check checksum of the binary if you decided to download it

```shell
$ shasum -a 256 terpd-v4.2.0-linux-amd64
<checksum>  terpd-v4.2.0-linux-amd64
```

## Copy the new terpd (v4.2.0) binary to cosmovisor current directory
```shell
   cp $GOPATH/bin/terpd ~/.terpd/cosmovisor/current/bin
```

## Restore service file settings

If you are using a service file, restore the previous `Restart` settings in your service file: 
```
Restart=On-failure 
```
Reload the service control `sudo systemctl daemon-reload`.

# Revert `terpd` configurations

Depending on which path you chose for Step 1, either:

* Reset `halt-height = 0` option in the `app.toml` or
* Remove it from start parameters of the terpd binary and start node again