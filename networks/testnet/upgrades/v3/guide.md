# Terp-Core v3 - Headstash Upgrade

|                 |                                                              |
|-----------------|--------------------------------------------------------------|
| Chain-id        | `90u-2`                                                |
| Upgrade Version | `v3.0.0`                                        |
| Upgrade Height  | `1084072`                                                      |



The target block for this upgrade is `1084072`, which is expected to arrive at 11:00UTC Wednesday, October 11th.. [Go Playground](https://go.dev/play/p/ZM8NGcIgECZ)

### Building Manually:
```
cd terp-core
git fetch --tags && git checkout v3.0.0 
make build && make install 

terpd version --long | grep "cosmos_sdk_veresion/|commit\|version:"
# commit: b0aa21fb41995ccf204b2738b3055572734769b7
# cosmos_sdk_version: v0.47.4
# version:3.0.0

mkdir -P $DAEMON_HOME/cosmovisor/upgrades/v3/bin && cp $HOME/go/bin/terpd $DAEMON_HOME/cosmovisor/upgrades/v3/bin 

$DAEMON_HOME/cosmovisor/upgrades/v3/bin/terpd version
```
### Downloading Verified Build:
```
rm -rf terpd_linux_amd64.tar.gz # delete if exists
wget https://github.com/terpnetwork/terp-core/releases/download/v3.0.0/terpd-v3.0.0-linux-amd64.tar.gz
sha256sum terpd_linux_amd64.tar.gz 
# Output 97bb24bdc446b9cbc200a12f9f6bdc8079eaf1243210ded5c59484b88143dca3
```