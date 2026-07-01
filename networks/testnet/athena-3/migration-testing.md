# Migration Testing Process

## Step 1: Test Intended Upgrades Functionality
- V0.4.0: [link]()
- Instantiate via gov testing
```
terpd tx gov submit-proposal instantiate-contract 1 '{}' --label "cw_admin_factory" --title "instantiate through gove test: admin factory" --no-admin --chain-id testing --gas 2000000 --fees 2000000upersyx --run-as terp16ltuapyk7hsztanwx6h6qzag93pp9pmuvtplv9 --from thiol --description "testing the process of instantiating a contract via governance"
```
- Governance Details: `terpd q gov proposal 1`
```
content:
  '@type': /cosmwasm.wasm.v1.InstantiateContractProposal
  admin: ""
  code_id: "1"
  description: testing the process of instantiating a contract via governance
  funds: []
  label: cw_admin_factory
  msg: {}
  run_as: terp16ltuapyk7hsztanwx6h6qzag93pp9pmuvtplv9
  title: 'instantiate through gove test: admin factory'
deposit_end_time: "REDACTED"
final_tally_result:
  abstain: "0"
  "no": "0"
  no_with_veto: "0"
  "yes": "0"
proposal_id: "1"
status: PROPOSAL_STATUS_VOTING_PERIOD
submit_time: "REDACTED"
total_deposit:
- amount: "1000000000"
  denom: uterpx
voting_end_time: "REDACTED"
voting_start_time: "REDACTED"
root@database:~/Projects# terpd q gov proposal 1content:  '@type': /cosmwasm.wasm.v1.InstantiateContractProposal  admin: ""
  code_id: "1"
  description: testing the process of instantiating a contract via governance
  funds: []
  label: cw_admin_factory
  msg: {}
  run_as: terp16ltuapyk7hsztanwx6h6qzag93pp9pmuvtplv9
  title: 'instantiate through gove test: admin factory'
deposit_end_time: "REDACTED"
final_tally_result:
  abstain: "0"
  "no": "0"
  no_with_veto: "0"
  "yes": "1000000000"
proposal_id: "1"
status: PROPOSAL_STATUS_PASSED
submit_time: "REDACTED"
total_deposit:
- amount: "1000000000"
  denom: uterpx
voting_end_time: "REDACTED"
voting_start_time: "REDACTED"
```
- check for the instantiated contract: `terpd q wasm list-contract-by-code 1`
```
- terp14hj2tavq8fpesdwxxcu44rty3hh90vhujrvcmstl4zr3txmfvw9skqhzr5
pagination:
  next_key: null
  total: "0"
```
Looking good! 
## Step 2: Test V0.3.0 -> v0.4.0 migration process
- mimic current network state (contracts w/ interactions)
- v0.4.0 sha256sum: `385ddad9bdfb5c62d998d18029a6ddb61f2cd0c8e80398aadc79713f70a41fae  terpd`
- export state 
- upgrade prop msg
```
terpd tx gov submit-proposal software-upgrade testing --upgrade-height 1300 --title "testing upgrade title" --description "testing description"  --from terpz --gas 3000000 --fees 3000000upersyx  --chain-id testing --upgrade-info '{"binaries": { "linux/amd64":"https://github.com/terpnetwork/terp-core/releases/download/v0.4.0-rc/terpd?checksum=sha256:385ddad9bdfb5c62d998d18029a6ddb61f2cd0c8e80398aadc79713f70a41fae" }}' 
```
- querying the proposal:
```
content:
  '@type': /cosmos.upgrade.v1beta1.SoftwareUpgradeProposal
  description: testing description
  plan:
    height: "1300"
    info: '{"binaries": { "linux/amd64":"https://github.com/terpnetwork/terp-core/releases/download/v0.4.0-rc/terpd?checksum=sha256:385ddad9bdfb5c62d998d18029a6ddb61f2cd0c8e80398aadc79713f70a41fae"
      }}'
    name: testing
    time: "0001-01-01T00:00:00Z"
    upgraded_client_state: null
  title: testing upgrade title
deposit_end_time: "REDACTED"
final_tally_result:
  abstain: "0"
  "no": "0"
  no_with_veto: "0"
  "yes": "1000000000"
proposal_id: "3"
status: PROPOSAL_STATUS_PASSED
submit_time: "REDACTED"
total_deposit:
- amount: "1000000000"
  denom: uterpx
voting_end_time: "REDACTED"
voting_start_time: "REDACTED"
```
- consensus log @ upgrade height
```
 ERR UPGRADE "testing" NEEDED at height: 1300: {"binaries": { "linux/amd64":"https://github.com/terpnetwork/terp-core/releases/download/v0.4.0-rc/terpd?checksum=sha256:385ddad9bdfb5c62d998d18029a6ddb61f2cd0c8e80398aadc79713f70a41fae" }}
4:57AM ERR CONSENSUS FAILURE!!! err="UPGRADE \"testing\" NEEDED at height: 1300: {\"binaries\": { \"linux/amd64\":\"https://github.com/terpnetwork/terp-core/releases/download/v0.4.0-rc/terpd?checksum=sha256:385ddad9bdfb5c62d998d18029a6ddb61f2cd0c8e80398aadc79713f70a41fae\" }}" module=consensus stack="goroutine 127 [running]:\nruntime/debug.Stack()\n\truntime/debug/stack.go:24...
```
## Step 3: Resume consensus with v0.4.0 
- Update Resources 
