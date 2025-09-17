package globalfee_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"github.com/stretchr/testify/suite"
	testutils "github.com/terpnetwork/terp-core/v4/app/testutil"

	"cosmossdk.io/math"

	sdk "github.com/cosmos/cosmos-sdk/types"

	"github.com/terpnetwork/terp-core/v4/x/globalfee"
	globalfeekeeper "github.com/terpnetwork/terp-core/v4/x/globalfee/keeper"
	"github.com/terpnetwork/terp-core/v4/x/globalfee/types"
)

type QuerierTestSuite struct {
	testutils.KeeperTestHelper
}

func (s *QuerierTestSuite) TestQueryMinimumGasPrices() {
	specs := map[string]struct {
		setupStore func(ctx sdk.Context, k *globalfeekeeper.Keeper)
		expMin     sdk.DecCoins
	}{
		"one coin": {
			setupStore: func(ctx sdk.Context, k *globalfeekeeper.Keeper) {
				err := k.SetParams(ctx, types.Params{
					MinimumGasPrices: sdk.NewDecCoins(sdk.NewDecCoin("ALX", math.OneInt())),
				})
				require.NoError(s.T(), err)
			},
			expMin: sdk.NewDecCoins(sdk.NewDecCoin("ALX", math.OneInt())),
		},
		"multiple coins": {
			setupStore: func(ctx sdk.Context, k *globalfeekeeper.Keeper) {
				err := k.SetParams(ctx, types.Params{
					MinimumGasPrices: sdk.NewDecCoins(sdk.NewDecCoin("ALX", math.OneInt()), sdk.NewDecCoin("BLX", math.NewInt(2))),
				})
				require.NoError(s.T(), err)
			},
			expMin: sdk.NewDecCoins(sdk.NewDecCoin("ALX", math.OneInt()), sdk.NewDecCoin("BLX", math.NewInt(2))),
		},
		"no min gas price set": {
			setupStore: func(ctx sdk.Context, k *globalfeekeeper.Keeper) {
				err := k.SetParams(ctx, types.Params{})
				require.NoError(s.T(), err)
			},
		},
		"no param set": {
			setupStore: func(ctx sdk.Context, k *globalfeekeeper.Keeper) {
			},
		},
	}
	for name, spec := range specs {
		s.T().Run(name, func(t *testing.T) {
			s.SetupTest()
			q := globalfee.NewGrpcQuerier(s.App.GlobalFeeKeeper)

			spec.setupStore(s.Ctx, s.App.GlobalFeeKeeper)
			gotResp, gotErr := q.MinimumGasPrices(s.Ctx, nil)
			require.NoError(t, gotErr)
			require.NotNil(t, gotResp)
			assert.Equal(t, spec.expMin, gotResp.MinimumGasPrices)
		})
	}
}

func TestKeeperTestSuite(t *testing.T) {
	suite.Run(t, new(QuerierTestSuite))
}

func (s *QuerierTestSuite) SetupTest() {
	s.Setup()
}
