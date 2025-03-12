package keeper_test

import (
	"testing"

	"github.com/stretchr/testify/suite"

	"github.com/cosmos/cosmos-sdk/baseapp"
	sdk "github.com/cosmos/cosmos-sdk/types"
	bankkeeper "github.com/cosmos/cosmos-sdk/x/bank/keeper"
	minttypes "github.com/cosmos/cosmos-sdk/x/mint/types"

	"github.com/terpnetwork/terp-core/v4/app"
	"github.com/terpnetwork/terp-core/v4/x/clock/keeper"
	"github.com/terpnetwork/terp-core/v4/x/clock/types"
)

type IntegrationTestSuite struct {
	suite.Suite

	ctx            sdk.Context
	app            *app.TerpApp
	bankKeeper     bankkeeper.Keeper
	queryClient    types.QueryClient
	clockMsgServer types.MsgServer
}

func (s *IntegrationTestSuite) SetupTest() {
	isCheckTx := false
	s.app = app.Setup(s.T())

	s.ctx = s.app.BaseApp.NewContext(isCheckTx)

	queryHelper := baseapp.NewQueryServerTestHelper(s.ctx, s.app.InterfaceRegistry())
	types.RegisterQueryServer(queryHelper, keeper.NewQuerier(s.app.ClockKeeper))

	s.queryClient = types.NewQueryClient(queryHelper)
	s.bankKeeper = s.app.BankKeeper
	s.clockMsgServer = keeper.NewMsgServerImpl(s.app.ClockKeeper)
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
