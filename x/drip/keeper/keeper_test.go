package keeper_test

import (
	"testing"

	"github.com/stretchr/testify/suite"

	"github.com/cosmos/cosmos-sdk/baseapp"
	sdk "github.com/cosmos/cosmos-sdk/types"
	minttypes "github.com/cosmos/cosmos-sdk/x/mint/types"

	"github.com/terpnetwork/terp-core/v4/app"
	"github.com/terpnetwork/terp-core/v4/x/drip/keeper"
	"github.com/terpnetwork/terp-core/v4/x/drip/types"
)

type IntegrationTestSuite struct {
	suite.Suite

	ctx           sdk.Context
	app           *app.TerpApp
	bankKeeper    types.BankKeeper
	queryClient   types.QueryClient
	dripMsgServer types.MsgServer
}

func (s *IntegrationTestSuite) SetupTest() {
	isCheckTx := false
	s.app = app.Setup(s.T())

	s.ctx = s.app.BaseApp.NewContext(isCheckTx)

	queryHelper := baseapp.NewQueryServerTestHelper(s.ctx, s.app.InterfaceRegistry())
	types.RegisterQueryServer(queryHelper, keeper.NewQuerier(s.app.AppKeepers.DripKeeper))

	s.queryClient = types.NewQueryClient(queryHelper)
	s.bankKeeper = s.app.AppKeepers.BankKeeper
	s.dripMsgServer = s.app.AppKeepers.DripKeeper
}

func (s *IntegrationTestSuite) FundAccount(ctx sdk.Context, addr sdk.AccAddress, amounts sdk.Coins) error {
	if err := s.bankKeeper.MintCoins(ctx, minttypes.ModuleName, amounts); err != nil {
		return err
	}

	return s.bankKeeper.SendCoinsFromModuleToAccount(ctx, minttypes.ModuleName, addr, amounts)
}

func TestKeeperTestSuite(t *testing.T) {
	suite.Run(t, new(IntegrationTestSuite))
}
