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

**Contract authors:** wasm-to-wasm `reply` events follow upstream wasmd
again. The v6.1 allowlist that dropped `instantiate` / `execute` from the
reply payload is not the rule. See [`REPLY-EVENTS.md`](./REPLY-EVENTS.md).

---

## Published tarballs

| Plan | Platform | sha256 |
|------|----------|--------|
| v6.3.0 | linux/amd64 | `302ad85a28f317fc54983c7cc47597820f40e2b6f0176703b89085d63f5d53bb` |
| v6.3.0 | linux/arm64 | `c26383a772625e240e8bf150b4249a4eafcf32b3a6076c82abfb9a64ce77fc06` |
| v6.4.0 | linux/amd64 | `c8fe6cf8cbf8ae0493732907c8b14614e6999a92534cc79717f92d2a977175e7` |
| v6.4.0 | linux/arm64 | `3b8c70ff76525c4dd647e45ec9550318a092433cf55acc067ef04d8710968d9e` |

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
`100000000000uterp` puts the proposal into voting immediately. Deposit it
by Thursday 2026-10-15 10:00 UTC so the vote ends as height `23893261`
arrives (Friday 2026-10-16 10:00 UTC). v6.4 is armed at `23893263`.
`plan.info` is pending the linux tarball checksums for this cut.

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
See [`../../../x/wasm/wasmvm/docs/BUILDERS.md`](../../../x/wasm/wasmvm/docs/BUILDERS.md).

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
