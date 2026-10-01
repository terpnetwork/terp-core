# v6.4 Cosmovisor binary (no second proposal)

There is **no** governance proposal named `v6.4`. The v6.3 handler arms this
plan at apply+2.

Operators: pre-place `upgrades/v6.4/bin/terpd` **before** the v6.3 height
`23674923` (Saturday 2026-10-03 10:00 UTC). v6.4 is armed at `23674925`.
See [`../v6.3/guide.md`](../v6.3/guide.md).

linux/amd64 `dedd89bcd84957aba2d6e9625ee546da6a72703825528ebfa57224b333173106`

linux/arm64 `33f2e37454eb47c81685ee67438c0ea5082c6a484fa5350766f81868f332fd0f`

Same 4.0.0-zk muslc as v6.3, built with `terpnetwork/zk-alpine-builder:4.0.0-zk`,
never `cosmwasm/libwasmvm-builder:0103-*`.
