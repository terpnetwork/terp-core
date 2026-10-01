# v6.3.0

Governance plan name: `v6.3`. Halt height `23674923` (2026-10-03 10:00 UTC).

The handler copies application stores onto BLAKE3 destination trees and arms
plan `v6.4` two blocks later. IBC stores stay SHA-256. The binary includes
wasmvm `4.0.0-zk` at `8117f41` (prefix iterator reports an error only while
the iterator is still valid).

Operator steps: [guide.md](./guide.md).

Tarballs: https://s3.terp.network/releases/terp-core/v6.3.0/

Cosmovisor: https://s3.terp.network/upgrades/v6.3/cosmovisor.json

Git commit the ELF was built from: `02599d268e93bc4a6455d00951e3abb5955f4383`.
