package exported

import sdk "github.com/cosmos/cosmos-sdk/types"

type (
	// ParamSet is the legacy x/params ParamSet surface, kept only so v2
	// migrations still compile. SDK 0.55 removed x/params.
	ParamSet interface {
		Validate() error
	}

	// Subspace is the legacy x/params Subspace surface used only by historical
	// wasm migrations. Pass nil on SDK 0.55+ (params already live in x/wasm).
	Subspace interface {
		GetParamSet(ctx sdk.Context, ps ParamSet)
	}
)
