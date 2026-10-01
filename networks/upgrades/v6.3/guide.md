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
- **Upgrade height (v6.3)**: `23674923` (Saturday 2026-10-03 10:00 UTC)
- **v6.4 height**: v6.3 apply **+ 2** (`23674925`)
- **Release**: https://s3.terp.network/releases/terp-core/v6.3.0/ · https://s3.terp.network/releases/terp-core/v6.4.0/
- **Cosmovisor JSON**: https://s3.terp.network/upgrades/v6.3/cosmovisor.json · https://s3.terp.network/upgrades/v6.4/cosmovisor.json

Linux **amd64** and **arm64** only. Do not put a darwin `terpd` under Cosmovisor.

**Do not start until v6.2 has applied.** v6.2 dropped dest; v6.3 is a new copy.

`ARTIFACT_LOCK` `published: true` matches the public tarball sha256 below.
Curators: [`CURATE.md`](./CURATE.md) · [`SOURCE_DEPS.txt`](./SOURCE_DEPS.txt).

Height was measured at block `23622006` (`2026-10-01T06:07:09Z`). The previous
2000 blocks averaged **3.529 s**. That rate reaches `23674923` at 10:00 UTC.
A flat 3.5 s/block from that same sample would be height `23675369`, about
25 minutes later if the chain keeps the measured rate. Re-measure before broadcast if the proposal is not
submitted on Thursday.

The wasmvm in these binaries reports a prefix-iterator error only while the
iterator is still valid, so a normal end-of-range scan no longer fails.

---

## Published tarballs

| Plan | Platform | sha256 |
|------|----------|--------|
| v6.3.0 | linux/amd64 | `4161cf4531f357ce4cec24e0302b71ca404810556b439729d43a120dd0972d65` |
| v6.3.0 | linux/arm64 | `3d28fe7a68e52c6bfcc696b71393c4cd5795d208c7c87f0ee4f6d65f44f6e4cf` |
| v6.4.0 | linux/amd64 | `dedd89bcd84957aba2d6e9625ee546da6a72703825528ebfa57224b333173106` |
| v6.4.0 | linux/arm64 | `33f2e37454eb47c81685ee67438c0ea5082c6a484fa5350766f81868f332fd0f` |

Cosmovisor verifies the `checksum=sha256:` query on the URL in
`cosmovisor.json`. The v6.3 binary has the v6.4 checksums compiled into it
and arms plan `v6.4` at apply+2. There is no second governance proposal.

---

## Expedited proposal (x/gov, not the DAO)

Submit one expedited `MsgSoftwareUpgrade` for plan **`v6.3` only**, from a
hot wallet. Do not route it through the DAO. The chain's passed proposals
are already applied (`current_plan` is empty; nothing is in voting or
deposit). The DAO's week-long revote cooldown does not apply to this path.

Expedited voting is **24 hours**. The full expedited deposit
`100000000000uterp` puts the proposal into voting immediately. Broadcast
early enough that those 24 hours end before height `23674923` (before
Friday 2026-10-02 10:00 UTC).

Download the versioned tarballs (`terpd-6.3.0-linux-amd64.tar.gz` and the
arm64 pair, and the same names for `6.4.0`). The bare `terpd-linux-amd64`
objects in those prefixes are an older generation and are not the checksums
above.

The mnemonic stays in this gitignored file, which you fill in by hand:

`/Users/returniflost/abstract/terp-core/crates/terp-rs/.env.v63-upgrade`

Dry-run (prints the proposal, does not broadcast):

```sh
cargo run --manifest-path crates/terp-rs/tools/v63-upgrade/Cargo.toml --release
```

Broadcast only after that dry-run matches this guide and `UPGRADE_BROADCAST=1`
is set in the env file. The script refuses while any proposal is in voting
or deposit, and it never submits plan `v6.4`.

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
(local compile; not published). Never `cosmwasm/libwasmvm-builder:0103-*`.
See [`../../../crates/zk-wasmvm/docs/BUILDERS.md`](../../../crates/zk-wasmvm/docs/BUILDERS.md).

Operators upgrade with the tarballs above. This cut did not republish
`registry.terp.network/terp-core:v6.3.0` or `:v6.4.0`.

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
