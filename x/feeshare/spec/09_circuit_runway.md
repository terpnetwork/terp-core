# Circuit runway (fee-share hook + reward pools)

Do **not** add a second fee-splitter. `x/feeshare` already takes a governance share of `MsgExecuteContract` gas. Circuit retention reuses that opt-in. **Where the coins go** is not the stake-weighted fee collector.

## Payment sink (50 / 50)

Every circuit-runway payment (`MsgPayCircuitDeposit`, later feeshare `circuit_runway` credit) splits:

| Share | Module account | Policy |
|-------|----------------|--------|
| 50% | `circuit_val_pool` | EndBlocker even split to **bonded operators** (one share each, **not** voting power) |
| 50% | `circuit_dev_pool` | Protocol maintenance fund. `Staking` permission so gov can later delegate; remainder after integer split stays here if odd uterp |

Odd leftover uterp on the initial split goes to the **dev** pool. Val-pool remainder after `amount % n_operators` stays in `circuit_val_pool` until the next block.

This is the point: small operators get the same runway payout as large ones. Stake-weighted `FeeCollector` → distribution is the wrong sink.

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
