# v6.4 upgrade ops (keepers on BLAKE3 dest)

**Validators:** [`../PROVIDERS-v6.3-v7.md`](../PROVIDERS-v6.3-v7.md) (plan dirs `v6.3` then `v6.4`).
This WORKFLOW is curator / soak.

Plan name **`v6.4`**. Binary tag **`v6.4.0`**. Do **not** register this plan on
the v6.3.0 binary (that binary only **arms** it). Hasher: [`../v6.3/HASHER.md`](../v6.3/HASHER.md).

v6.4 is Upgrade B for hasher. v6.2 dropped dest. v6.4 does the opposite: dest
(BLAKE3) stays live; SHA-256 migratable names leave CommitInfo.

1. **ELF** `-tags v64` (or `feat/6.4.0-dev`). Same iavl + store/v2 replaces.
2. **`GenerateKeys`:** do **not** mount live SHA-256 migratable names. Mount dest
   `b3-*`. Map module `StoreKey` constants → dest via `KeeperKey`. Empty `Renamed`.
3. **StoreUpgrades:** `Deleted` = previous live SHA-256 migratable names. Empty
   `Added`. Empty `Renamed`.
4. **Handler:** dest keys must exist; live names must be absent; IBC unchanged;
   no further plan.
5. **TSH** `make tsh-upgrade-v63` applies v6.3 then v6.4. After B: dest bank
   membership is BLAKE3; `ibc` is SHA-256.

## Do not

- Register `v6.4` on the v6.3 binary.
- Rename dest onto `bank` / `staking` / `acc`.
- Flip `DefaultOptions` to BLAKE3.
- Tag or `git push` from this workflow.
