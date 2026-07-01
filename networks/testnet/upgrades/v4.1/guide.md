# Terp-Core v4.1.testnet - Farnesene Upgrade

|                 |                                                              |
|-----------------|--------------------------------------------------------------|
| Chain-id        | `90u-2`                                                      |
| Upgrade Version | `v4.1.testnet`                                               |
| Upgrade Height  | `1850763`                                                    |



The target block for this upgrade is `1850763`, which is expected to arrive at 11:00UTC Wednesday, November 29th.. [Go Playground](https://go.dev/play/p/Nj1h7QjNWGS)

### Building Manually:
```
cd terp-core
cd terp-core && git pull && git checkout v4.1.testnet
make build && make install 

terpd version --long | grep "cosmos_sdk_veresion/|commit\|version:"
# commit: 4756161c4cb9993a12c33c40121862224a3e1eaa
# cosmos_sdk_version: v0.47.5
# version: 4.1.testnet

mkdir -P $DAEMON_HOME/cosmovisor/upgrades/v4_1/bin && cp $HOME/go/bin/terpd $DAEMON_HOME/cosmovisor/upgrades/v4_1/bin 

$DAEMON_HOME/cosmovisor/upgrades/v4_1/bin/terpd version
```
### Downloading Verified Build:
```
rm -rf terpd_linux_amd64.tar.gz # delete if exists
wget https://github.com/terpnetwork/terp-core/releases/download/v4.1.testnet/terpd-v4.1.testnet-linux-amd64.tar.gz
sha256sum terpd-v4.0.0-linux-amd64.tar.gz
# Output 0cf4de9d41d2285b71b396783d5e1f05569a7d20f64b9c133c1c737a64c3992d  terpd-linux-amd64.tar.gz
```