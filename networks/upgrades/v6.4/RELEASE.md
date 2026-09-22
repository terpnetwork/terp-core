# v6.4.0 release notes

No second governance proposal. The v6.3 handler arms plan **`v6.4`** at
apply height **+ 2**. Binary tag **`v6.4.0`** (`224419a`). Same source as
the pre-checksum v6.3 tree, built with **`-tags v64`**.

## What changed

- Keepers read the dest `b3-*` stores. Inner nodes are BLAKE3.
- IBC-facing stores stay SHA-256.
- Same 4.0.0-zk muslc as v6.3.0. Do not reuse the v6.1 muslc hashes.

## Artifacts

Published:

- https://s3.terp.network/releases/terp-core/v6.4.0/
- https://s3.terp.network/upgrades/v6.4/cosmovisor.json

Those tarball checksums are the ones compiled into the **v6.3.0** binary
(`NextUpgradeInfo`). Rebuilding v6.4 without moving tag `v6.4.0` is what
keeps that info true.

Operators pre-place `upgrades/v6.4/bin/terpd` before the v6.3 height, or
let Cosmovisor download it and check the sha256 in `plan.info`.

The published tarball was linked with plain `-static`. Later release builds
use `ld.bfd` and `-static-pie`. Do not replace the published object with a
rebuild from that newer link unless you also move the checksum inside v6.3.
