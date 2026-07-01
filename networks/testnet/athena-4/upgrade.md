---
title: Terp-Core Upgrade v0.4.0 -
---
<!-- markdown-link-check-disable -->
# Terp-Core Upgrade Instructions

The following document describes the necessary steps involved that full-node operators
must take in order to upgrade from `athena-3`to `athena-4`. 

## Steps Took To Generate Valid Genesis File
- exported state @ upgrade height `782686`
- Addition of `x/terp` genesis state params:
```json
{
    "terp": {
            "params": {},
            "terpidList": [],
            "terpidCount": "0",
            "supplychainList": [],
            "supplychainCount": "0"
        }
}
```

## Upgrade Procedure

__Note__: It is assumed you are currently operating a node running on athena-3.

- The upgrade height if agreed upon by governance: `782686` [go playground link](https://go.dev/play/p/u8UNNS9uOx0)


```bash
terpd version
```
### 1. Stop your service when reached `782686`:
```bash
terpd stop
or
systemctl stop terpd.service
```
### 1.1 (Optional) backup your ~/.terp folder. 
### 2. Upgrade binary to v0.4.0

```bash
cd terp-core 
git fetch --all 
git checkout v0.4.0
make install
```
 __NOTE__: If running checkout does not work; remove terp-core, download it again and repeat step 3(Only terp-core not .terp).
```bash
rm -r terp-core
git clone -b hard-nett/v0.4.0 https://github.com/terpnetwork/terp-core
```
      
### 3. Verify you are currently running the correct version (v0.4.0) of the Terp-Core:
```bash
terpd version --long 
```
the output should be
      
```bash
name: terpnetwork
server_name: terpd
version: 0.4.0 
commit: cc8513a6cad512e5d3c54cfa0e710dfa010ab98f
build_tags: netgo,ledger 
go: go version go1.19.2 linux/amd64 
```
### 4. Download Genesis file for v0.4.0
```bash
curl -s  https://raw.githubusercontent.com/terpnetwork/test-net/master/athena-4/genesis.json > ~/.terp/config/genesis.json
```
### 4.1 Validate sha256sum of genesis (TBD)
```bash 
sha256sum ~/.terp/config/genesis.json  
```
should return for **athena-4** genesis:
 ```c181e312eb6f349ac2921ad4250a588f3323ecf1b30c8b3455ce075d43107916  /home/athena-3/.terp/config/genesis.json```
 
### 5. Unsafe reset and Start terpd.
```bash
terpd tendermint unsafe-reset-all --home $HOME/.terp --keep-addr-book
terpd start
```
<!-- markdown-link-check-enable -->
