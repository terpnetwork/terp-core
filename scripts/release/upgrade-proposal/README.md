# terp-upgrade-proposal

cw-orch CLI that submits `networks/upgrades/v6/draft_proposal.json` as
`/cosmos.gov.v1.MsgSubmitProposal` wrapping `MsgSoftwareUpgrade`.

## Mnemonic location

Copy the example env (gitignored; never commit `.env`):

```sh
cp scripts/release/.env.example scripts/release/.env
# set MAIN_MNEMONIC and GRPC_URL
```

`MAIN_MNEMONIC` is the cw-orch mainnet wallet env var.

## Dry-run (default)

```sh
make upgrade-proposal
# or
cd scripts/release/upgrade-proposal
cargo run --release -- --env-file ../.env
```

## Broadcast

Requires a reachable gRPC and deposit balance (`10000000000uterp` for the v6 pack).

```sh
make upgrade-proposal BROADCAST=1
# or
cargo run --release -- --env-file ../.env --broadcast
```
