package drip_test

import (
	"fmt"
	"testing"

	"github.com/stretchr/testify/suite"

	sdk "github.com/cosmos/cosmos-sdk/types"

	"github.com/terpnetwork/terp-core/v4/app"
	drip "github.com/terpnetwork/terp-core/v4/x/drip"
	"github.com/terpnetwork/terp-core/v4/x/drip/types"
)

type GenesisTestSuite struct {
	suite.Suite

	ctx sdk.Context

	app     *app.TerpApp
	genesis types.GenesisState
}

func TestGenesisTestSuite(t *testing.T) {
	suite.Run(t, new(GenesisTestSuite))
}

func (s *GenesisTestSuite) SetupTest() {
	app := app.Setup(s.T())
	ctx := app.BaseApp.NewContext(true)

	s.app = app
	s.ctx = ctx

	s.genesis = *types.DefaultGenesisState()
}

func (s *GenesisTestSuite) TestDripInitGenesis() {
	testCases := []struct {
		name     string
		genesis  types.GenesisState
		expPanic bool
	}{
		{
			"default genesis",
			s.genesis,
			false,
		},
		{
			"custom genesis - drip enabled, no one allowed",
			types.GenesisState{
				Params: types.Params{
					EnableDrip:       true,
					AllowedAddresses: []string(nil),
				},
			},
			false,
		},
		{
			"custom genesis - drip enabled, only one addr allowed",
			types.GenesisState{
				Params: types.Params{
					EnableDrip:       true,
					AllowedAddresses: []string{"terp1v6vlpuqlhhpwujvaqs4pe5dmljapdev4plqfds"},
				},
			},
			false,
		},
		{
			"custom genesis - drip enabled, 2 addr allowed",
			types.GenesisState{
				Params: types.Params{
					EnableDrip:       true,
					AllowedAddresses: []string{"terp1v6vlpuqlhhpwujvaqs4pe5dmljapdev4plqfds", "terp1hq2p69p4kmwndxlss7dqk0sr5pe5mmcpcxyh5h"},
				},
			},
			false,
		},
		{
			"custom genesis - drip enabled, address invalid",
			types.GenesisState{
				Params: types.Params{
					EnableDrip:       true,
					AllowedAddresses: []string{"terp1v6vllollollollollolloldmljapdev4s827ql"},
				},
			},
			true,
		},
	}

	for _, tc := range testCases {
		s.Run(fmt.Sprintf("Case %s", tc.name), func() {
			s.SetupTest() // reset

			if tc.expPanic {
				s.Require().Panics(func() {
					drip.InitGenesis(s.ctx, s.app.AppKeepers.DripKeeper, tc.genesis)
				})
			} else {
				s.Require().NotPanics(func() {
					drip.InitGenesis(s.ctx, s.app.AppKeepers.DripKeeper, tc.genesis)
				})

				params := s.app.AppKeepers.DripKeeper.GetParams(s.ctx)
				s.Require().Equal(tc.genesis.Params, params)
			}
		})
	}
}
