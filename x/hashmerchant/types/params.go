package types

import (
	"cosmossdk.io/math"

	wasmtypes "github.com/CosmWasm/wasmd/x/wasm/types"
)

// Wasm instance memory is 32 MiB (wasmd keeper contractMemoryLimit).
// DefaultCompileCost is SDK gas per bytecode byte. The sudo budget is the
// compile cost of a max-size blob so the number is recoverable from gas.go.
const (
	SudoMemoryLimitBytes    = 32 << 20 // 32 MiB
	DefaultContractGasLimit = SudoMemoryLimitBytes * wasmtypes.DefaultCompileCost
)

// DefaultParams returns the default module parameters.
func DefaultParams() Params {
	return Params{
		QuorumFraction:   math.LegacyMustNewDecFromStr("0.667"),
		PruneInterval:    1000,
		EscrowDenom:      "uterp",
		MinEscrowAmount:  math.NewInt(1_000_000), // 1 TERP
		MarketMode:       MarketMode_MARKET_MODE_OPEN,
		ContractGasLimit: DefaultContractGasLimit,
	}
}

// SudoGasLimit is the SDK gas meter cap for one sudo callback.
// Zero (legacy params) uses DefaultContractGasLimit.
func (p Params) SudoGasLimit() uint64 {
	if p.ContractGasLimit == 0 {
		return DefaultContractGasLimit
	}
	return p.ContractGasLimit
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
