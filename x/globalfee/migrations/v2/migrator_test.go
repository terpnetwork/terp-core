package v2_test

import (
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/cosmos/cosmos-sdk/testutil"
	sdk "github.com/cosmos/cosmos-sdk/types"
	moduletestutil "github.com/cosmos/cosmos-sdk/types/module/testutil"

	"github.com/terpnetwork/terp-core/v4/x/globalfee"
	"github.com/terpnetwork/terp-core/v4/x/globalfee/keeper/exported"
	v2 "github.com/terpnetwork/terp-core/v4/x/globalfee/migrations/v2"
	"github.com/terpnetwork/terp-core/v4/x/globalfee/types"
)

//lint:ignore U1000 disregard lint check
type mockSubspace struct {
	ps types.Params
}

//lint:ignore U1000 disregard lint check
func newMockSubspace(ps types.Params) mockSubspace {
	return mockSubspace{ps: ps}
}

func (ms mockSubspace) GetParamSet(_ sdk.Context, ps exported.ParamSet) {
	*ps.(*types.Params) = ms.ps
}

func TestMigrateMainnet(t *testing.T) {
	encCfg := moduletestutil.MakeTestEncodingConfig(globalfee.AppModuleBasic{})
	cdc := encCfg.Codec

	storeKey := sdk.NewKVStoreKey(v2.ModuleName)
	tKey := sdk.NewTransientStoreKey("transient_test")
	ctx := testutil.DefaultContext(storeKey, tKey)
	store := ctx.KVStore(storeKey)

	params := types.Params{
		MinimumGasPrices: sdk.DecCoins{
			sdk.NewDecCoinFromDec("uthiol", sdk.NewDecWithPrec(75, 3)),
		},
	}

	require.NoError(t, v2.Migrate(ctx, store, cdc, "uthiol"))

	var res types.Params
	bz := store.Get(v2.ParamsKey)
	require.NoError(t, cdc.Unmarshal(bz, &res))
	require.Equal(t, params, res)
}

func TestMigrateTestnet(t *testing.T) {
	encCfg := moduletestutil.MakeTestEncodingConfig(globalfee.AppModuleBasic{})
	cdc := encCfg.Codec

	storeKey := sdk.NewKVStoreKey(v2.ModuleName)
	tKey := sdk.NewTransientStoreKey("transient_test")
	ctx := testutil.DefaultContext(storeKey, tKey)
	store := ctx.KVStore(storeKey)

	params := types.Params{
		MinimumGasPrices: sdk.DecCoins{
			sdk.NewDecCoinFromDec("uthiolx", sdk.NewDecWithPrec(75, 3)),
		},
	}

	require.NoError(t, v2.Migrate(ctx, store, cdc, "uthiolx"))

	var res types.Params
	bz := store.Get(v2.ParamsKey)
	require.NoError(t, cdc.Unmarshal(bz, &res))
	require.Equal(t, params, res)
}
