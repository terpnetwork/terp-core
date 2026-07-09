# Terp-Core v3 - Ocimene Upgrade

|                 |                                                              |
|-----------------|--------------------------------------------------------------|
| Chain-id        | `90u-2`                                                |
| Upgrade Version | `v4.0.0`                                        |
| Upgrade Height  | `1556462`                                                      |



The target block for this upgrade is `1556462`, which is expected to arrive at 11:00UTC Friday, November 10th.. [Go Playground](https://go.dev/play/p/hSvLK1iLENE)

### Building Manually:
```
cd terp-core
cd terp-core && git pull && git checkout v4.0.0
make build && make install 

terpd version --long | grep "cosmos_sdk_veresion/|commit\|version:"
# commit: 0a94d73f33bd759e701675c51d3b97ffc2f008b3
# cosmos_sdk_version: v0.47.5
# version: 4.0.0

mkdir -P $DAEMON_HOME/cosmovisor/upgrades/v4/bin && cp $HOME/go/bin/terpd $DAEMON_HOME/cosmovisor/upgrades/v4/bin 

$DAEMON_HOME/cosmovisor/upgrades/v4/bin/terpd version
```
### Downloading Verified Build:
```
rm -rf terpd_linux_amd64.tar.gz # delete if exists
wget https://github.com/terpnetwork/terp-core/releases/download/v4.0.0/terpd-v4.0.0-linux-amd64.tar.gz
sha256sum terpd-v4.0.0-linux-amd64.tar.gz
# Output 
```