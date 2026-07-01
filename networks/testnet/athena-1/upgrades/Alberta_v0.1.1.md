


## Please replace current `v0.1.0` by `v0.1.1`


Here are a trunicated upgrade tutorial for v0.1.1 of terp-core:

> Stop your current daemon (terpd or Cosmovisor) 
```
sudo systemctl stop terpd.service 
```

> Download the new Binary

``` 
git clone -b v0.1.1 https://github.com/terpnetwork/terp-core.git
cd terp-core
git checkout v0.1.1
make build && make install
```


> Another important step to make: add this text to `.terp/config/app.toml`
```
# IAVLDisableFastNode enables or disables the fast node feature of IAVL. 
# Default is true.
iavl-disable-fastnode = false
```


# Check Version
```
terpd version 
```
>>  `v0.1.1-...`

# Restart Node

```
 terpd start --unsafe-skip-upgrades 694200
```