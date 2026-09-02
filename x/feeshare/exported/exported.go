package exported

import sdk "github.com/cosmos/cosmos-sdk/types"

// ParamSet is the leftover x/params surface used only by the 1→2 migrator.
type ParamSet interface {
	Validate() error
}

// Subspace is the leftover x/params Subspace used only by the 1→2 migrator.
// Pass nil on SDK 0.55 (params already live in the feeshare store).
type Subspace interface {
	GetParamSet(ctx sdk.Context, ps ParamSet)
}
