# v6.3 upgrade ops (hasher ON the ELF)

**Validators (morocco-1):** [`../PROVIDERS-v6.3-v7.md`](../PROVIDERS-v6.3-v7.md)
and [`guide.md`](./guide.md) once those exist. This WORKFLOW is curator / soak.

**Do not start this until v6.1/v6.2 has applied on the target chain.** v6.2
dropped `b3-*`. v6.3 is a **new** dual-store copy with BLAKE3 actually compiled.

Plan name **`v6.3`**. Binary tag **`v6.3.0`**. Chain soak: **120u-1**.
Hasher contract: [`HASHER.md`](./HASHER.md) (hybrid vs full BLAKE3 **after**
[`BENCH.md`](./BENCH.md)). Sprint: [`SPRINT.md`](./SPRINT.md).

Fresh-VM: `TAG=v6.3.0 ./scripts/release/fresh-vm/run.sh` (extras
`scripts/release/fresh-vm/releases/v6.3.0.sh` must **fail** if `go.mod` lacks
iavl + store/v2 replaces).

Do these in order. **Do not broadcast** a gov proposal until heights are
filled. `releases/zk-wasmvm/v4.0.0-zk/` is on S3. Builder images stay
**local**. Operator registry is `registry.terp.network/terp-core:<tag>`
(see [`REGISTRY-HANDOFF.md`](./REGISTRY-HANDOFF.md)). Linux terpd tarballs
stay `published: false` until fresh-VM sha256 is in `ARTIFACT_LOCK`.

1. **Branch** `feat/6.3.0-dev` from post-v6.2 HEAD. Vendor patched IAVL v1 +
   store/v2 **in git** (`crates/cosmos/iavl`, `crates/cosmos/store-v2`). Run
   `scripts/release/curate_v63.sh` (must fail-closed without replaces).

2. **`AlgorithmName` dual-store** (live SHA-256, dest BLAKE3, IBC SHA-256).
   Unit tests: `bank`→sha256, `b3-bank`→blake3, `ibc`→sha256.

3. **Register plan `v6.3`** in `app/upgrades/v6_3` (copy shape from `v6_1`:
   `Added: iavl.DestStores()`). Handler KV-copies migratable stores.
   Refuse copy of `SHA256Stores`. Arm plan `v6.4` at `BlockHeight()+2`.

4. **Compile** linux muslc ELFs from a fresh guest (rebuild muslc + fetch
   ibc-hooks tarball). `WASMVM_SOURCE=local`.

   ```sh
   TAG=v6.3.0 PLATFORMS=linux/amd64,linux/arm64 ./scripts/release/fresh-vm/run.sh
   PLAN=v6.3 make recurate-upgrade-binaries   # ARTIFACT_LOCK, after lock exists
   ```

5. **TSH** `make tsh-upgrade` (morocco-1 pruned pack + in-place-testnet by
   default). After A: dest bank proof is BLAKE3; `ibc` proof still SHA-256.
   After B (`v6.4`): keepers on dest; live SHA-256 names dropped; populated
   wasm codes / module queries retained; 08-wasm LC accepts dest-bank
   membership. Bit-for-bit linux ELFs: [`CURATE.md`](./CURATE.md). Dep
   tags: [`DEPS-RELEASE.md`](./DEPS-RELEASE.md).

6. **Measure height** on 120u-1. Fill `draft_proposal.json`. `plan.info` is
   Cosmovisor JSON, never `file://`. Do not broadcast.

## Do not

- Retag `v6.1.0` / `v6.2.0`.
- Set IAVL `DefaultOptions` to BLAKE3.
- `StoreUpgrades.Renamed` dest onto `bank` on this binary.
- Ship if `go.mod` lacks the two replaces.
- Claim hasher from `AlgorithmName` without a node dump / proof.
