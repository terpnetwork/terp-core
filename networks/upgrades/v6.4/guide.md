# v6.4 Cosmovisor binary (no second proposal)

There is **no** governance proposal named `v6.4`. The v6.3 handler arms this
plan at apply+2.

Operators: pre-place `upgrades/v6.4/bin/terpd` **before** the v6.3 height
`23674923` (Saturday 2026-10-03 10:00 UTC). v6.4 is armed at `23674925`.
See [`../v6.3/guide.md`](../v6.3/guide.md).

linux/amd64 `c8fe6cf8cbf8ae0493732907c8b14614e6999a92534cc79717f92d2a977175e7`

linux/arm64 `3b8c70ff76525c4dd647e45ec9550318a092433cf55acc067ef04d8710968d9e`

Same 4.0.0-zk muslc as v6.3, built with `terpnetwork/zk-alpine-builder:4.0.0-zk`,
never `cosmwasm/libwasmvm-builder:0103-*`.
