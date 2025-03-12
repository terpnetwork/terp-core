package keeper_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"cosmossdk.io/math"

	sdk "github.com/cosmos/cosmos-sdk/types"

	appparams "github.com/terpnetwork/terp-core/v4/app/params"
	"github.com/terpnetwork/terp-core/v4/x/globalfee"
	"github.com/terpnetwork/terp-core/v4/x/globalfee/types"
)

func (s *KeeperTestSuite) TestDefaultGenesis() {
	encCfg := appparams.MakeEncodingConfig()
	gotJSON := globalfee.AppModuleBasic{}.DefaultGenesis(encCfg.Marshaler)
	assert.JSONEq(s.T(), `{"params":{"minimum_gas_prices":[]}}`, string(gotJSON), string(gotJSON))
}

func (s *KeeperTestSuite) TestValidateGenesis() {
	encCfg := appparams.MakeEncodingConfig()
	specs := map[string]struct {
		src    string
		expErr bool
	}{
		"all good": {
			src: `{"params":{"minimum_gas_prices":[{"denom":"ALX", "amount":"1"}]}}`,
		},
		"empty minimum": {
			src: `{"params":{"minimum_gas_prices":[]}}`,
		},
		"minimum not set": {
			src: `{"params":{}}`,
		},
		"zero amount allowed": {
			src:    `{"params":{"minimum_gas_prices":[{"denom":"ALX", "amount":"0"}]}}`,
			expErr: false,
		},
		"duplicate denoms not allowed": {
			src:    `{"params":{"minimum_gas_prices":[{"denom":"ALX", "amount":"1"},{"denom":"ALX", "amount":"2"}]}}`,
			expErr: true,
		},
		"negative amounts not allowed": {
			src:    `{"params":{"minimum_gas_prices":[{"denom":"ALX", "amount":"-1"}]}}`,
			expErr: true,
		},
		"denom must be sorted": {
			src:    `{"params":{"minimum_gas_prices":[{"denom":"ZLX", "amount":"1"},{"denom":"ALX", "amount":"2"}]}}`,
			expErr: true,
		},
		"sorted denoms is allowed": {
			src:    `{"params":{"minimum_gas_prices":[{"denom":"ALX", "amount":"1"},{"denom":"ZLX", "amount":"2"}]}}`,
			expErr: false,
		},
	}
	for name, spec := range specs {
		s.T().Run(name, func(t *testing.T) {
			gotErr := globalfee.AppModuleBasic{}.ValidateGenesis(encCfg.Marshaler, nil, []byte(spec.src))
			if spec.expErr {
				require.Error(t, gotErr)
				return
			}
			require.NoError(t, gotErr)
		})
	}
}

func (s *KeeperTestSuite) TestInitExportGenesis() {

	specs := map[string]struct {
		src string
		exp types.GenesisState
	}{
		"single fee": {
			src: `{"params":{"minimum_gas_prices":[{"denom":"ALX", "amount":"1"}]}}`,
			exp: types.GenesisState{Params: types.Params{MinimumGasPrices: sdk.NewDecCoins(sdk.NewDecCoin("ALX", math.NewInt(1)))}},
		},
		"multiple fee options": {
			src: `{"params":{"minimum_gas_prices":[{"denom":"ALX", "amount":"1"}, {"denom":"BLX", "amount":"0.001"}]}}`,
			exp: types.GenesisState{Params: types.Params{MinimumGasPrices: sdk.NewDecCoins(sdk.NewDecCoin("ALX", math.NewInt(1)),
				sdk.NewDecCoinFromDec("BLX", math.LegacyNewDecWithPrec(1, 3)))}},
		},
		"no fee set": {
			src: `{"params":{}}`,
			exp: types.GenesisState{Params: types.Params{MinimumGasPrices: sdk.DecCoins{}}},
		},
	}
	for name, spec := range specs {
		s.T().Run(name, func(t *testing.T) {
			s.SetupTestStore()

			defaultParams := types.DefaultParams()
			defaultParams = spec.exp.Params
			s.App.GlobalFeeKeeper.SetParams(s.Ctx, defaultParams)

			params := s.App.GlobalFeeKeeper.GetParams(s.Ctx)
			s.Require().Equal(params.String(), spec.exp.Params.String())

			genState := s.App.GlobalFeeKeeper.ExportGenesis(s.Ctx)
			s.Require().Equal(genState.Params.String(), spec.exp.Params.String())

		})
	}
}

func (s *KeeperTestSuite) SetupTestStore() {
	s.SetupTest(false)
	return
}
