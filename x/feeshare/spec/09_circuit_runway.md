# Circuit runway (fee-share hook + reward pools)

Do **not** add a second fee-splitter. `x/feeshare` already takes a governance share of `MsgExecuteContract` gas. Circuit retention reuses that opt-in. **Where the coins go** is not the stake-weighted fee collector.

## Payment sink (50 / 50)

Every circuit-runway payment (`MsgPayCircuitDeposit`, later feeshare `circuit_runway` credit) splits:

| Share | Module account | Policy |
|-------|----------------|--------|
| 50% | `circuit_val_pool` | Accrues until the **circuit epoch** ends. Then paid **fairly** to operators who were bonded **and live** in that epoch (not voting power, not a headcount that includes offline). |
| 50% | `circuit_dev_pool` **or** `params.circuit_dev_destination` | Maintenance share. Empty param → module account `circuit_dev_pool` (`Staking`-capable). Non-empty bech32 → that wallet or contract (DAO). Gov `MsgUpdateParams`. |

Odd leftover uterp on the **payment** split goes to the **dev** pool. Val-pool remainder after integer settle (`amount % weight_sum` dust) stays in `circuit_val_pool` until the next epoch.

This is the point: runway is **not** `FeeCollector` → `x/distribution` (that is power-weighted F1). Small live operators are not diluted by large stake. Offline / jailed / unbonding operators are not paid as if they secured the set. **Fair, not even.**

## Timer: Osmosis `x/epochs`, wasm is a hook consumer

Do **not** invent a second clock. Osmosis `x/epochs` is the generalized on-chain timer; mint, incentives, protorev only **filter** `epochIdentifier` and run on `AfterEpochEnd`. We take that shape.

| Osmosis lesson | Circuit runway |
|---|---|
| Identifier (`day` / `week`), not a hardcoded height | wasm param `circuit_distr_epoch_identifier` (gov). Hook no-ops on any other id. |
| `AfterEpochEnd(ctx, id, epochNumber)` is the only settle | `DistributeCircuitValPool` moves **off** every-block EndBlocker onto that hook. |
| Accrue all epoch, one distribution, leftover balance is truth | Payments only `Send` into `circuit_val_pool`. Settle reads the bag once. |
| Gauge `DistributedCoins` / remainder | Integer coins; unpaid dust stays in the module account. No share tokens. |
| Skip ineligible recipients; do not fail the block on one send | Skip jailed / not bonded / below min signed; log + continue. |
| Measure the period you are paying | Participation score is **this epoch**, not lifetime uptime. |
| `BeforeEpochStart` is usually empty | Snapshot slashing `MissedBlocksCounter` (and bonded set) here if we need a delta; otherwise read the window at end. |

Terp-core does **not** mount `x/epochs` today. Adding it is a **new KV store** (`epochs`) — that is a later `StoreUpgrades.Added`, **not** v6.1/v6.2 hasher work.

Until the epochs store exists, wasm may hold a **copy of Osmosis `EpochInfo`** (identifier, duration, `current_epoch`, `current_epoch_start_time`, `current_epoch_start_height`) and tick it from EndBlocker the same way `x/epochs` BeginBlocker does (first block whose time is past `start + duration` is the end). The settle function is `AfterEpochEnd` either way. When `x/epochs` is mounted, delete the local ticker and register the hook. Do not keep two clocks.

Default identifier: `day`. Duration: 24h, aligned to genesis or first enable. Gov can point wasm at `week` later without changing payout math.

## Fair settle (live participation, not headcount, not power)

At `AfterEpochEnd` for the configured identifier:

1. Read `circuit_val_pool` balances. Empty → return.
2. Bonded validators at **this block** (epoch-end set). Unbonding / jailed: weight 0.
3. For each bonded operator, **participation weight** over the epoch:
   - `signed = SignedBlocksWindow - MissedBlocksCounter` using `x/slashing` signing info at epoch end (rolling window is the SDK signal we already have; if we snapshot missed at `BeforeEpochStart`, prefer `missed_end - missed_start` clipped to `[0, epoch_length]` so the score is the epoch we are paying).
   - If jailed, tombstoned, or `signed < min_signed_per_window` (reuse slashing `MinSignedPerWindow` unless wasm sets `circuit_val_min_signed` > 0): weight **0**.
   - Else weight = `signed` (not 1). A val that signed the whole window earns more than one that skimmed the minimum. That is fair. Equal-among-live (weight 1 or 0) is a gov-switch if we need simpler ops, default is **uptime weight**.
4. `weight_sum = Σ weight`. If 0 (all offline): **pay nobody**; bag stays in the pool for the next epoch (do not send to community pool — that reintroduces stake-adjacent mixing).
5. For each operator with weight > 0: `share = pool_amount * weight / weight_sum` (integer). Send to the **operator account**, not F1 outstanding. Delegators do not take circuit rent unless a later upgrade explicitly opts into `AllocateTokensToValidator`.
6. Dust (`pool - Σ shares`) stays in `circuit_val_pool`.
7. Emit `circuit_val_pool_payout` (`epoch_number`, `epoch_identifier`, `eligible`, `weight_sum`, `paid`, `skipped`).

Join mid-epoch: eligible if bonded **and** live at settle (Osmosis-style: the set at tick, no backfill). Leave before settle: not in the bonded list, weight 0, no clawback of prior epochs (those coins already left the pool).

Developer / contract routing of small renewal or execute credits: still **payment-time** 50/50 into the two pools (later a third `circuit_creator` share if we add it). Do not route per-validator at claim time.

## What does not move to the epoch

`PruneExpiredCircuitDeposits` stays a **bounded every-block** GC. Expiry is wall-clock coverage, not payday. Do not wait for `AfterEpochEnd` to drop circuits — that would leave expired blobs up to 24h and spike the epoch block. Optional: extra prune pass on epoch end is fine; it is not the only pass.

`x/distribution` / staking-hooks-for-F1: out of scope. Hooks are allowed only to maintain a bonded-operator index (`AfterValidatorBonded` / `AfterValidatorBeginUnbonding`) so settle does not depend on `GetBondedValidatorsByPower` remaining cheap.

## Upgrade soundness

| Halt | Circuit payout |
|---|---|
| v6.1 wasm (`ConsensusVersion` 5) | Local Osmosis-shaped `EpochInfo` (`day`, 24h). `TickCircuitEpoch` in wasm EndBlocker; fair settle on `AfterEpochEnd`. Empty identifier still runs legacy every-block split. Hasher dual-store is independent. |
| Later | Replace local ticker with mounted `x/epochs`; same `AfterEpochEnd`. |

Hasher dual-store and circuit economics are independent. Mixing them in one halt is how this stops being sound.

## ICTRS (live 3-validator set)

Go keeper tests cover weights. Docker covers **bonded set change**.

```sh
make build-zk-local   # terpnetwork/terp-core:local-zk (this wasm)
make e2e-circuit-runway          # ICT_MOCK=1 pay/query
make e2e-circuit-runway-docker   # 3 vals, CIRCUIT_EPOCH_DURATION_SECONDS=12, unbond leaver
```

`crates/ict-rs/examples/circuit_runway_epoch.rs`: pay → epoch → all operators gain; unbond validator-2 → pay → leaver operator does not gain. Image must include the env-duration ticker. Mock cannot collect 3 gentxs.

## Pro-rata time (utilization)

Yearly list is `1_000_000uterp`. Execute fees are smaller, so feeshare credits (later) extend time by:

```
delta_seconds = fee_amount * SecondsPerYear / yearly_fee_amount
paid_until    = max(paid_until, now) + delta_seconds
```

`MsgPayCircuitDeposit{years}` is CLI sugar for `years * yearly_fee` into the 50/50 pools, then the same time formula.

## Fee-share registration (later)

One bool on existing `FeeShare`: `circuit_runway`. If true, the execute-fee **share** is moved `FeeCollector → val/dev pools` (50/50) and credits `withdrawer`'s deposit clock. If false, cash to withdrawer as today.

Until then: feeshare withdrawer = depositor, then that wallet calls `pay-circuit-deposit`.

## Dev pool

Holds the maintenance half. Query: `terpd q auth module-account circuit_dev_pool` / bank balances. Spend or delegate is a later gov message on this account (already `Staking`-capable). Not the community pool — that is still stake-adjacent and mixed with other inflows.
