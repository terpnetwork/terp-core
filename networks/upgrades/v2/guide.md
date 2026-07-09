# Terp-Core v2 - Humulene Upgrade

|                 |                                                              |
|-----------------|--------------------------------------------------------------|
| Chain-id        | `morocco-1`                                                |
| Upgrade Version | `v2.0.0`                                        |
| Upgrade Height  | `2847602`                                              |
| Countdown       | [Countdown](https://ping.pub/terp/block/2847602)                                             |



The target block for this upgrade is `2763907`, which is expected to arrive at Wednesday, October 11th.. 

### Building Manually:
```
cd terp-core
git fetch --tags && git checkout v2.0.0 
make build && make install 

terpd version --long | grep "cosmos_sdk_veresion/|commit\|version:"
# commit: abaa4aea743ed104ae6009d62d034bd2a3bc4b93
# cosmos_sdk_version: v0.47.3
# version: 2.0.0

mkdir -P $DAEMON_HOME/cosmovisor/upgrades/v2/bin && cp $HOME/go/bin/terpd $DAEMON_HOME/cosmovisor/upgrades/v2/bin 

$DAEMON_HOME/cosmovisor/upgrades/v2/bin/terpd version
```
### Downloading Verified Build:
```
rm -rf terpd_linux_amd64.tar.gz # delete if exists
wget https://github.com/terpnetwork/terp-core/releases/download/v2.0.0/terpd-v2.0.0-linux-amd64.tar.gz
sha256sum terpd_linux_amd64.tar.gz 
# Output 832b8907aa5977c1dd07ec31f54ec3c46e6998222dd3e28ea588c011b99a5dcc
```
