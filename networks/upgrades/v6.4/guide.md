# v6.4 Cosmovisor binary (no second proposal)

There is **no** governance proposal named `v6.4`. The v6.3 handler arms this
plan at apply+2.

Operators: pre-place `upgrades/v6.4/bin/terpd` **before** the v6.3 height.
See [`../v6.3/guide.md`](../v6.3/guide.md).

Same 4.0.0-zk muslc as v6.3, built with `terpnetwork/zk-alpine-builder:4.0.0-zk`,
never `cosmwasm/libwasmvm-builder:0103-*`.
