# Rolling CosmWasm halt patch (v6.0 line)

This is **not** the v6.1 / v6.2 coordinated upgrade. It is a **binary swap**
on the live **v6.0.0** line so a CosmWasm `Ok == nil` result cannot panic the
process (HashMerchant PreBlocker sudo, execute, migrate, IBC recv).

morocco-1 today: **SDK 0.54.3**, **CometBFT 0.39.3**, **wasm consensus 4**,
**wasmvm v3.0.7-zk**. Do **not** run the v6.1.0 / v6.2.0 binaries for this
patch. Those are SDK **0.55** + CometBFT **0.40** + wasm **4→5** and only
apply at the gov halt (`v6.1` plan, proposal 59).

## What this branch is

- Branch: `patch/v6.0-cosmwasm-halt` (from tag `v6.0.0`)
- wasmd: `permissionlessweb/wasmd` `patch/v0.70-sdk54-nil-ok` @ `d733e9b3`
  (live pin `2d5821c1` + nil-Ok guards only)
- `x/wasm` **ConsensusVersion stays 4** (no store migration)
- Upgrade handlers: **v5, v520, v6 only**. No `v6.1`, no `v6.2`.

## What this branch is not

- Not SDK 0.55 / CometBFT 0.40 wasmd (that is the upcoming gov upgrade).
- Not wasm consensus 5 / `Migrate4to5`.
- Not a gov software-upgrade plan. There is **no halt height**.

## Validator steps

1. Build **this** branch (linux amd64 or arm64), same muslc / wasmvm as v6.0.0.
2. Stop `terpd` / Cosmovisor.
3. Replace the **currently running** binary:
   - Cosmovisor: `$DAEMON_HOME/cosmovisor/current/bin/terpd` (usually
     `genesis/bin/terpd` until v6.1).
   - Not Cosmovisor: wherever `ExecStart` points.
4. Start again. Do **not** create `upgrades/v6.1` for this patch.
5. Confirm `terpd version` matches the patch build and the node keeps
   producing / following blocks.

Coordinate the swap. A mixed set of old/new binaries is a halt-vs-error
fork the first time a contract returns `{}` (nil Ok). Low activity helps;
still swap **every** validator and sentry before that tx lands.

After proposal 59 passes, you still halt at **23191300** and apply **v6.1**
then **v6.2** via Cosmovisor as in `networks/upgrades/PROVIDERS-v6.1-v6.2.md`.
This patch binary must **not** be used at that height.
