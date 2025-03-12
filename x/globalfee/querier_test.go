package globalfee_test

import (
	"testing"
	"time"

	storetypes "cosmossdk.io/store/types"
	cmtproto "github.com/cometbft/cometbft/proto/tendermint/types"
	cosmosdb "github.com/cosmos/cosmos-db"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	ap "github.com/terpnetwork/terp-core/v4/app/params"

	"cosmossdk.io/log"
	"cosmossdk.io/math"
	"cosmossdk.io/store"

	sdk "github.com/cosmos/cosmos-sdk/types"

	"github.com/terpnetwork/terp-core/v4/x/globalfee"
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
			q := globalfee.NewGrpcQuerier(keeper)
			gotResp, gotErr := q.MinimumGasPrices(sdk.WrapSDKContext(ctx), nil)
			require.NoError(t, gotErr)
			require.NotNil(t, gotResp)
			assert.Equal(t, spec.expMin, gotResp.MinimumGasPrices)
		})
	}
}

func setupTestStore(t *testing.T) (sdk.Context, ap.EncodingConfig, globalfeekeeper.Keeper) {
	t.Helper()
	db := cosmosdb.NewMemDB()
	ms := store.NewCommitMultiStore(db, log.NewNopLogger(), nil)
	encCfg := ap.MakeEncodingConfig()
	keyParams := storetypes.NewKVStoreKey(types.StoreKey)

	ms.MountStoreWithDB(keyParams, storetypes.StoreTypeIAVL, db)
	require.NoError(t, ms.LoadLatestVersion())

	globalfeeKeeper := globalfeekeeper.NewKeeper(encCfg.Marshaler, keyParams, "terp1jv65s3grqf6v6jl3dp4t6c9t9rk99cd8q4dsrv")

	ctx := sdk.NewContext(ms, cmtproto.Header{
		Height:  1234567,
		Time:    time.Date(2020, time.April, 22, 12, 0, 0, 0, time.UTC),
		ChainID: "testing",
	}, false, log.NewNopLogger())

	return ctx, encCfg, globalfeeKeeper
}
