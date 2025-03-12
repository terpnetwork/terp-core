package globalfee

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"cosmossdk.io/math"

	sdk "github.com/cosmos/cosmos-sdk/types"

	globalfeekeeper "github.com/terpnetwork/terp-core/v4/x/globalfee/keeper"
	"github.com/terpnetwork/terp-core/v4/x/globalfee/types"
)

func TestQueryMinimumGasPrices(t *testing.T) {
	specs := map[string]struct {
		setupStore func(ctx sdk.Context, k globalfeekeeper.Keeper)
		expMin     sdk.DecCoins
	}{
		"one coin": {
			setupStore: func(ctx sdk.Context, k globalfeekeeper.Keeper) {
				err := k.SetParams(ctx, types.Params{
					MinimumGasPrices: sdk.NewDecCoins(sdk.NewDecCoin("ALX", math.OneInt())),
				})
				require.NoError(t, err)
			},
			expMin: sdk.NewDecCoins(sdk.NewDecCoin("ALX", math.OneInt())),
		},
		"multiple coins": {
			setupStore: func(ctx sdk.Context, k globalfeekeeper.Keeper) {
				err := k.SetParams(ctx, types.Params{
					MinimumGasPrices: sdk.NewDecCoins(sdk.NewDecCoin("ALX", math.OneInt()), sdk.NewDecCoin("BLX", math.NewInt(2))),
				})
				require.NoError(t, err)
			},
			expMin: sdk.NewDecCoins(sdk.NewDecCoin("ALX", math.OneInt()), sdk.NewDecCoin("BLX", math.NewInt(2))),
		},
		"no min gas price set": {
			setupStore: func(ctx sdk.Context, k globalfeekeeper.Keeper) {
				err := k.SetParams(ctx, types.Params{})
				require.NoError(t, err)
			},
		},
		"no param set": {
			setupStore: func(ctx sdk.Context, k globalfeekeeper.Keeper) {
			},
		},
	}
	for name, spec := range specs {
		t.Run(name, func(t *testing.T) {
			ctx, _, keeper := setupTestStore(t)
			spec.setupStore(ctx, keeper)
			q := NewGrpcQuerier(keeper)
			gotResp, gotErr := q.MinimumGasPrices(sdk.WrapSDKContext(ctx), nil)
			require.NoError(t, gotErr)
			require.NotNil(t, gotResp)
			assert.Equal(t, spec.expMin, gotResp.MinimumGasPrices)
		})
	}
}
