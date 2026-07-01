## Steps after upgrade height halt

### 1. Export for Zero height
```
terpd export --for-zero-height >> 90u-upgrade-export.json
```
### 2. The following modifications on the exported genesis are needed for a valid v1.0.1 genesis file:
- consensus version key
```
    "version": {
      "app": "0"
    }
```
- add 07-tendermint key
```
  "app_state": {
    "07-tendermint": null,
    ...}
```
- add `send_enabled` under `denom_metadata`:
```
      "denom_metadata": [],
      "send_enabled": [],
```
- add `consensus` type above `crisis`type:
```
 "consensus": null,
    "crisis": {...
```
- modify gov param types: (note we are restarting governance here.)
```
    "gov": {
      "starting_proposal_id": "1",
      "deposits": [],
      "votes": [],
      "proposals": [],
      "deposit_params": null,
      "voting_params": null,
      "tally_params": null,
      "params": {
        "min_deposit": [
          {
            "denom": "uterp",
            "amount": "10000000"
          }
        ],
        "max_deposit_period": "172800s",
        "voting_period": "172800s",
        "quorum": "0.334000000000000000",
        "threshold": "0.500000000000000000",
        "veto_threshold": "0.334000000000000000",
        "min_initial_deposit_ratio": "0.000000000000000000",
        "burn_vote_quorum": false,
        "burn_proposal_deposit_prevote": false,
        "burn_vote_veto": true
      }
    },
```
- add the `group` key:
```
  "group": {
      "group_seq": "0",
      "groups": [],
      "group_members": [],
      "group_policy_seq": "0",
      "group_policies": [],
      "proposal_seq": "0",
      "proposals": [],
      "votes": []
    },
```
- modify `allowed-messages`:
```
"allow_messages": [
            "*"
          ],
```
- add `nft` key:
```
    "nft": {
      "classes": [],
      "entries": []
    },
```
- add `min_comission_rate` below `bond_denom`:
```
 "params": {
                "bond_denom": "uterpx",
                "min_commission_rate": "0.000000000000000000",
 }
                ...
```
- replace `terp` keys with `tokenfactory`:
```
"tokenfactory": {
      "params": {
        "denom_creation_fee": [
          {
            "denom": "uthiol",
            "amount": "10000000"
          }
        ]
      },
      "factory_denoms": []
    },
```

Once you have done this, we can verify a succesfuly migration by building the new daemon and `validate-genesis` to confirm the migration accuracy. 

