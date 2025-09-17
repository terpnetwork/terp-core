package clock_test

import (
	"fmt"
	"testing"

	"github.com/stretchr/testify/suite"

	"github.com/cosmos/cosmos-sdk/testutil/testdata"
	sdk "github.com/cosmos/cosmos-sdk/types"

	"github.com/terpnetwork/terp-core/v4/app"
	clock "github.com/terpnetwork/terp-core/v4/x/clock"
	"github.com/terpnetwork/terp-core/v4/x/clock/types"
)

type GenesisTestSuite struct {
	suite.Suite

	ctx sdk.Context

	app *app.TerpApp
}

func TestGenesisTestSuite(t *testing.T) {
	suite.Run(t, new(GenesisTestSuite))
}

func (s *GenesisTestSuite) SetupTest() {
	app := app.Setup(false)
	ctx := app.BaseApp.NewContext(false)

	s.app = app
	s.ctx = ctx
}

func (s *GenesisTestSuite) TestClockInitGenesis() {
	_, _, addr := testdata.KeyTestPubAddr()
	_, _, addr2 := testdata.KeyTestPubAddr()

	defaultParams := types.DefaultParams()

	testCases := []struct {
		name     string
		genesis  types.GenesisState
		expPanic bool
	}{
		{
			"default genesis",
			*clock.DefaultGenesisState(),
			false,
		},
		{
			"custom genesis - none",
			types.GenesisState{
				Params: types.Params{
					ContractAddresses: []string(nil),
					ContractGasLimit:  defaultParams.ContractGasLimit,
				},
			},
			false,
		},
		{
			"custom genesis - incorrect addr",
			types.GenesisState{
				Params: types.Params{
					ContractAddresses: []string{"incorrectaddr"},
					ContractGasLimit:  defaultParams.ContractGasLimit,
				},
			},
			true,
		},
		{
			"custom genesis - only one addr allowed",
			types.GenesisState{
				Params: types.Params{
					ContractAddresses: []string{addr.String(), addr2.String()},
					ContractGasLimit:  defaultParams.ContractGasLimit,
				},
			},
			false,
		},
	}

	for _, tc := range testCases {
		s.Run(fmt.Sprintf("Case %s", tc.name), func() {
			s.SetupTest() // reset

			if tc.expPanic {
				s.Require().Panics(func() {
					clock.InitGenesis(s.ctx, s.app.ClockKeeper, tc.genesis)
				})
			} else {
				s.Require().NotPanics(func() {
					clock.InitGenesis(s.ctx, s.app.ClockKeeper, tc.genesis)
				})

				params := s.app.ClockKeeper.GetParams(s.ctx)
				s.Require().Equal(tc.genesis.Params, params)
			}
		})
	}
}
