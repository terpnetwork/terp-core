
## I. Export Balances from 90u-1.

[Exporting the balances](../90u-1/genesis.json) of test-net 90u-1. The results should be identical to [exported-balances.json](./exported-balances.json).

## II. Run new-balance-state script for creating the new genesis file. 

Migration details:

- `upersyx` denomination is migrated to `uthiolx`.
- The only inital balances involve `uterpx` & `uthiolx`. Accounts on the test network that include another native denom or ibc bridged token denom will be documented for historical purposes, but not included. 
- Any account that only held an ibc denom or native token that which was not `uterpx` or `upersyx` will be supplied with `1 Terpx` & `1 Thiolx` in the initial genesis state. 
- `chain-id` changed to `90u-2`.
- Gov deposit info migrated to `uterpx`.
- Contract state data will be reset. 
- Tokens accumulated in the community pool module account will initially start out in the base account used as the faucet, and subsequently deposited back into the community pool module account. 

