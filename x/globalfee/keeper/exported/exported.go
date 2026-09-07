package exported

import sdk "github.com/cosmos/cosmos-sdk/types"

type ParamSet interface {
	Validate() error
}

type Subspace interface {
	GetParamSet(ctx sdk.Context, ps ParamSet)
}
