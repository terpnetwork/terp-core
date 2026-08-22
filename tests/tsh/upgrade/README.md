# Upgrade From Latest Main-net state

Ensure live network data does not corrupt upgrade integrity.

```sh
sh a.sh
```

## D — existing CosmWasm guests across the v6 VM upgrade

Mirrors `b.sh` (local genesis + gov `software-upgrade` named `v6`) and proves a
contract stored on the **current** mainnet binary still **queries and executes**
after the new binary (metered `bulk_memory`) takes over.

```sh
# needs terp-mainnet on PATH (v5.x, no bulk_memory) and this tree installed as terpd
sh d.sh
```

Claim if it exits 0: updating the VM to support bulk memory does not brick
existing smart contracts from working.


## E — Cosmovisor auto-swap at v6

Mirrors `b.sh` but starts the node with **Cosmovisor**. Genesis binary is
`terp-mainnet`; `upgrades/v6/bin/terpd` is this tree. The process must stay up
across halt.

```sh
make tsh-upgrade-cv
# or: SKIP_INSTALL=1 sh e.sh
```
