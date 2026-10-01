# v7 upgrade ops (superseded on this tree)

**This cut ships Upgrade B as plan `v6.4`**, not `v7`. See
[`../v6.4/WORKFLOW.md`](../v6.4/WORKFLOW.md) and
[`../v6.3/CURATE.md`](../v6.3/CURATE.md). Keep this file as the older name.

# v7 upgrade ops (keepers on BLAKE3 dest; drop SHA-256 copies)

**Validators:** [`../PROVIDERS-v6.3-v7.md`](../PROVIDERS-v6.3-v7.md).
This WORKFLOW is curator / soak.

Plan name **`v7`**. Binary tag **`v7.0.0`**. Do **not** register this plan on
the v6.3.0 binary (that binary only **arms** it). Hasher: [`../v6.3/HASHER.md`](../v6.3/HASHER.md).

v7 is Upgrade B for hasher. v6.2 already used plan `v6.2` to **drop dest**.
v7 does the opposite: dest (BLAKE3) stays live; SHA-256 migratable names leave
CommitInfo.

1. **Branch** `feat/7.0.0-dev` from `feat/6.3.0-dev` after v6.3 handler is
   frozen. Same iavl + store/v2 replaces **on the tag**.

2. **`AlgorithmName`:** IBC SHA-256; migratable live names **BLAKE3** (keepers
   now read dest data). No `b3-*` mounts.

3. **`GenerateKeys`:** do **not** append `DestStores()`. Wire keepers to dest
   trees **without** `StoreUpgrades.Renamed` onto `bank` (IAVL rejects
   initialVersion on a name that already has history — TSH on v6.2).

   Keep dest **store key strings** (`b3-bank`, …) as the mounted names, and
   map module `StoreKey` constants → dest keys in app wiring. Queries that
   hardcode `"bank"` as an IAVL prefix must go through that map.

4. **StoreUpgrades:** `Deleted` = previous live SHA-256 migratable names
   (`bank`, `staking`, `acc`, …). Empty `Added`. Empty `Renamed`.

5. **Handler:** log mounted keys; refuse if dest missing; RunMigrations; IBC
   untouched. Do **not** arm a further plan unless asked.

6. **Fresh-VM** `TAG=v7.0.0`. Extras fail if replaces missing.

7. **TSH** `make tsh-upgrade-v63` already applied v6.3+v7 if Cosmovisor has
   both bins (same dual-halt as v61.sh). Post-v7: raw IAVL `b3-bank` (or mapped
   bank) inner nodes are not SHA-256; `ibc` still is.

## Do not

- Register `v7` on the v6.3 binary.
- Rename dest onto `bank` / `staking` / `acc`.
- Unmount dest before keepers read it.
- Flip `DefaultOptions` to BLAKE3.
