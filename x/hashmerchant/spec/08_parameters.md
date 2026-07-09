<!--
order: 8
-->

# Parameters

The `x/hashmerchant` module parameters are stored at KVStore prefix `0x05` and can be updated via `MsgUpdateParams` (governance-only).

## Parameter Table

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `quorum_fraction` | `LegacyDec` | `0.667` | Minimum fraction of total voting power required to confirm a root |
| `prune_interval` | `uint64` | `1000` | Number of blocks between escrow pruning cycles |
| `escrow_denom` | `string` | `uterp` | Token denomination accepted for escrow payments |
| `min_escrow_amount` | `math.Int` | `1000000` | Minimum escrow deposit (1 TERP = 1,000,000 uterp) |
| `market_mode` | `MarketMode` | `OPEN` | Who can provide attestations |

## quorum_fraction

The weighted voting power threshold a state root must reach to be confirmed. Expressed as a decimal between 0 and 1.

- `0.667` (default): Matches the standard BFT 2/3 supermajority, ensuring a confirmed root cannot be forged unless 1/3+ of voting power is malicious
- `0.5`: Lower threshold, faster confirmation but weaker security guarantees
- `1.0`: Requires all validators to agree (not practical)

Governance should carefully consider the security implications before lowering this parameter.

## prune_interval

How often (in blocks) the module checks for expired escrow deposits and disables associated contracts.

- `1000` (default): With ~6s block times, pruning runs approximately every 100 minutes
- Lower values increase pruning frequency but add marginal per-block overhead
- Higher values reduce overhead but delay the disablement of expired contracts

This value also determines the "unit of time" for escrow payments:
```
paid_blocks = (escrow_amount / min_escrow_amount) * prune_interval
```

## escrow_denom

The token denomination contracts must use when paying escrow. Only one denomination is accepted at a time.

## min_escrow_amount

The minimum escrow deposit required to register a contract. Also serves as the divisor for computing `paid_until_height`:

```
periods = deposit / min_escrow_amount
paid_until_height = current_height + (periods * prune_interval)
```

With defaults: 1,000,000 uterp (1 TERP) buys 1,000 blocks of callbacks.

## market_mode

Controls who can submit vote extension attestations:

| Value | Name | Description |
|-------|------|-------------|
| `0` | `MARKET_MODE_UNSPECIFIED` | Invalid / not set |
| `1` | `MARKET_MODE_OPEN` | Any active validator may attest (default) |
| `2` | `MARKET_MODE_CLOSED` | Only governance-whitelisted providers may attest |

## Updating Parameters

Parameters are updated via a governance proposal:

```bash
terpd tx gov submit-proposal update-params \
  --title "Adjust hashmerchant quorum" \
  --description "Lower quorum to 60% for faster root confirmation" \
  --deposit 10000000uterp \
  --from mykey
```

Or directly via `MsgUpdateParams` if the sender is the governance module:

```bash
terpd tx hashmerchant update-params \
  --quorum-fraction "0.600" \
  --prune-interval 500 \
  --from governance-module-address
```
