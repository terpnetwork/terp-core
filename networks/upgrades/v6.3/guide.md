# Mainnet Upgrade Guide: v6.3 then v6.4 (BLAKE3 dest IAVL)

## Overview

Coordinated software upgrade on **morocco-1**. Two Cosmovisor swaps about
**two blocks** apart. Governance submits **only** plan **`v6.3`**. The v6.3
binary arms **`v6.4`** at apply+2.

This is the hasher cutover v6.1/v6.2 did **not** ship (hasher never compiled).
IBC stores stay **SHA-256**. Migratable app stores move to dest `b3-*` trees
whose inner nodes are **BLAKE3**.

- **Chain**: `morocco-1`
- **Plan names**: `v6.3` then `v6.4` (not `v7`)
- **Git tags / binaries**: `v6.3.0` then `v6.4.0` (`-tags v64`)
- **Upgrade height (v6.3)**: TBD
- **v6.4 height**: v6.3 apply **+ 2**
- **Release** (after publish): https://s3.terp.network/releases/terp-core/v6.3.0/ · https://s3.terp.network/releases/terp-core/v6.4.0/
- **Cosmovisor JSON** (after publish): https://s3.terp.network/upgrades/v6.3/cosmovisor.json · https://s3.terp.network/upgrades/v6.4/cosmovisor.json

Linux **amd64** and **arm64** only. Do not put a darwin `terpd` under Cosmovisor.

**Do not start until v6.2 has applied.** v6.2 dropped dest; v6.3 is a new copy.

`ARTIFACT_LOCK` is `published: true`. What this binary does, and the
checksums it arms for v6.4, are in [`RELEASE.md`](./RELEASE.md).
Curators: [`CURATE.md`](./CURATE.md) · [`SOURCE_DEPS.txt`](./SOURCE_DEPS.txt).

---

## Cosmovisor (required)

Same install as v6.1 if you already run `cosmovisor run start`. Pre-place
**both** binaries **before** the v6.3 height:

```sh
export DAEMON_HOME="${DAEMON_HOME:-$HOME/.terpd}"
install -m 0755 /path/to/terpd-v6.3.0 "$DAEMON_HOME/cosmovisor/upgrades/v6.3/bin/terpd"
install -m 0755 /path/to/terpd-v6.4.0 "$DAEMON_HOME/cosmovisor/upgrades/v6.4/bin/terpd"
"$DAEMON_HOME/cosmovisor/upgrades/v6.3/bin/terpd" version   # 6.3.0
"$DAEMON_HOME/cosmovisor/upgrades/v6.4/bin/terpd" version   # 6.4.0
```

If Cosmovisor lacks `upgrades/v6.4/bin/terpd`, **your node stays halted while
the network moves on.**

Plan directory names are **`v6.3` and `v6.4`**, not `v6.3.0`.

---

## What changes

| After | App stores (bank, staking, wasm, …) | IBC (`ibc`, `transfer`, ICA, …) |
|-------|-------------------------------------|----------------------------------|
| v6.3  | dest `b3-*` copied, BLAKE3 inner nodes; live names still SHA-256 | SHA-256 |
| v6.4  | keepers on dest; live SHA-256 names deleted | SHA-256 |

Do not rename `b3-bank` onto `bank`.

WasmVM on these ELFs is **4.0.0-zk** (Go import still `wasmvm/v3`): Path A
fail-closed (no dummy Flock/DSTW placeholders), zakura Halo2 IPA.

Host libs are built with **our** `terpnetwork/zk-*-builder:4.0.0-zk` images
(local compile; not published). Operator image is
`registry.terp.network/terp-core:v6.3.0` / `:v6.4.0`. Never
`cosmwasm/libwasmvm-builder:0103-*`. See
[`../../../crates/zk-wasmvm/docs/BUILDERS.md`](../../../crates/zk-wasmvm/docs/BUILDERS.md).

---

## Confirm after halt (operators)

```sh
terpd status
# two swaps: current should be upgrades/v6.4
terpd q bank params
terpd q staking validators
terpd q wasm list-code --limit 5
terpd debug hasher-proof --all --node tcp://127.0.0.1:26657
# expect: dest b3-bank=blake3 …  ibc=sha256
```

Curator TSH (populated morocco-1 pack): `make tsh-upgrade`.
