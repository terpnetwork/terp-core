# Terp-Core Upgrade Instructions

The following document describes the necessary steps involved that full-node operators
must take in order to upgrade from `athena-4`to `90u-1`. 

## Steps Took To Generate Valid Genesis File
- exported state @ upgrade height `1037222`
- Addition of `terp-core v1.0.1` genesis state params: [90-u genesis file migration](./export-migration.md)

## Upgrade Procedure

__Note__: It is assumed you are currently operating a node running on athena-4.

- The upgrade height if agreed upon by governance: `1037222` [go playground link](https://go.dev/play/p/LaNphVrg2mB)


```bash
terpd version
```
### 1. Stop your service when reached `1037222`:

```
systemctl stop terpd.service
```
### 1.1 (Optional) backup your ~/.terp folder. 
### 2. Upgrade binary to v1.0.1

```bash
cd terp-core 
git fetch --all 
git checkout v1.0.1
make install
```
 __NOTE__: If running checkout does not work; remove terp-core, download it again and repeat step 3(Only terp-core not .terp).
```bash
rm -r terp-core
git clone -b v1.0.1 https://github.com/terpnetwork/terp-core
```
      
### 3. Verify you are currently running the correct version (v1.0.1) of the Terp-Core:
```bash
terpd version --long 
```
the output should be
      
```bash
name: terpnetwork
server_name: terpd
version: 1.0.1
commit: 9bb91afded0ad182d97e642afddf0a45e0b4c438
build_tags: netgo,ledger 
```
### 4. Download Genesis file for 90u-1
```bash
curl -s  https://raw.githubusercontent.com/terpnetwork/test-net/master/90u-1/genesis.json > $HOME/.terp/config/genesis.json
```
### 4.1 Validate sha256sum of genesis (TBD)
```bash 
sha256sum $HOME/.terp/config/genesis.json  
```
should return for **90u-1** genesis:
 ```TBD  $HOME/.terp/config/genesis.json```
 
### 5. Unsafe reset and Start terpd.
```bash
terpd tendermint unsafe-reset-all --home $HOME/.terp --keep-addr-book
```

### 6. Set min gas fee
```
sed -i 's/minimum-gas-prices = "[^"]*"/minimum-gas-prices = "0.0002uthiol"/' $HOME/.terp/config/app.toml 
```
<!-- markdown-link-check-enable -->
