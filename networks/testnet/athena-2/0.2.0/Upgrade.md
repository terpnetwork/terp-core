---
title: Terp-Core Upgrade 0.2.0 -
---
<!-- markdown-link-check-disable -->
# Terp-Core Upgrade Instructions

The following document describes the necessary steps involved that full-node operators
must take in order to upgrade from `0.1.2` to `0.2.0`. 

## Steps Took To Generate Valid Genesis File

- Removal of `"gen_msg":[]` from genesis
- Addition of:
```
"feeibc": {
            "fee_enabled_channels": [],
            "forward_relayers": [],
            "identified_fees": [],
            "registered_counterparty_payees": [],
            "registered_payees": []
        },
```
- Removal of wasm contract state *all contracts uploaded by core contrubtors :)*

## Recovery

It is critically important to back-up the `.terp/data/priv_validator_state.json` file after stopping your terpd process. This file is updated every block as your validator participates in a consensus rounds. It is a critical file needed to prevent double-signing, in case the upgrade fails and the previous chain needs to be restarted.


## Upgrade Procedure

__Note__: It is assumed you are currently operating a full-node running v0.1.2 of the Terp-Core.

- The upgrade height as agreed upon by governance: __1,497,396__ [go playground link](https://go.dev/play/p/DOtb4m6OqCk)

1. Verify you are currently running the correct version (v0.1.2) of the Terp-Core:

   ```bash
   $ terpd version
   0.1.2
   ```

2. Stop your service when reached __1,497,396__:

   ```bash
   terpd stop
   or
   systemctl stop terpd.service
   ```

3. Upgrade binary to 0.2.0
   
   ```bash
   cd terp-core && git checkout main
   make install
   ```
 __NOTE__: If checkout not found main remove terp-core, download it again and repeat step 3(Olny terp-core not .terp).
 
   ```bash
   rm -r terp-core
   git clone https://github.com/terpnetwork/terp-core
   ```
   
4. Verify you are currently running the correct version (v0.2.0) of the Terp-Core:

   ```bash
   terpd version
   0.2.0
   ```

5. Download Genesis file for 0.2.0
  ```bash
  curl -s  https://raw.githubusercontent.com/terpnetwork/test-net/master/athena-2/0.2.0/genesis-patch.json > ~/.terp/config/genesis.json
  ```

6. Unsafe reset and Start terpd.
   Because of this is extremly important backup your validator files included .terp to restore at 0.1.2. 

  ```bash
  terpd tendermint unsafe-reset-all --home $HOME/.terp --keep-addr-book
  terpd start
  ```

<!-- markdown-link-check-enable -->
