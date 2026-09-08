package types

import (
	"cosmossdk.io/math"
)

// Wasm instance memory is 32 MiB. DefaultCompileCost is 3 SDK gas per bytecode
// byte. Used as the rolling-patch sudo meter cap without a params store write
// (v6.1 ConsensusVersion 2 / ContractGasLimit stays on the gov upgrade).
const (
	SudoMemoryLimitBytes    = 32 << 20
	DefaultContractGasLimit uint64 = SudoMemoryLimitBytes * 3
)

// DefaultParams returns the default module parameters.
func DefaultParams() Params {
	return Params{
		QuorumFraction:  math.LegacyMustNewDecFromStr("0.667"),
		PruneInterval:   1000,
		EscrowDenom:     "uterp",
		MinEscrowAmount: math.NewInt(1_000_000), // 1 TERP
		MarketMode:      MarketMode_MARKET_MODE_OPEN,
	}
}

// Validate checks that Params fields are sane.
func (p Params) Validate() error {
	if p.QuorumFraction.IsNegative() || p.QuorumFraction.GT(math.LegacyOneDec()) {
		return ErrInvalidParams.Wrapf("quorum_fraction must be in [0, 1], got %s", p.QuorumFraction)
	}
	if p.PruneInterval == 0 {
		return ErrInvalidParams.Wrap("prune_interval must be > 0")
	}
	if p.EscrowDenom == "" {
		return ErrInvalidParams.Wrap("escrow_denom must not be empty")
	}
	if p.MinEscrowAmount.IsNegative() {
		return ErrInvalidParams.Wrap("min_escrow_amount must be >= 0")
	}
	return nil
}
