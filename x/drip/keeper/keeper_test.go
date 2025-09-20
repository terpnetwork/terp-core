package keeper_test

import (
	"testing"

	"github.com/stretchr/testify/suite"

	"github.com/cosmos/cosmos-sdk/baseapp"
	sdk "github.com/cosmos/cosmos-sdk/types"
	minttypes "github.com/cosmos/cosmos-sdk/x/mint/types"

	testutils "github.com/terpnetwork/terp-core/v5/app/testutil"
	"github.com/terpnetwork/terp-core/v5/x/drip/keeper"
	"github.com/terpnetwork/terp-core/v5/x/drip/types"
)

type IntegrationTestSuite struct {
	testutils.KeeperTestHelper

	queryClient   types.QueryClient
	dripMsgServer types.MsgServer
}

func (s *IntegrationTestSuite) SetupTest() {
	s.Setup()

	queryHelper := baseapp.NewQueryServerTestHelper(s.Ctx, s.App.InterfaceRegistry())
	types.RegisterQueryServer(queryHelper, keeper.NewQuerier(s.App.DripKeeper))

	s.queryClient = types.NewQueryClient(queryHelper)
	s.dripMsgServer = s.App.DripKeeper
}

func (s *IntegrationTestSuite) FundAccount(ctx sdk.Context, addr sdk.AccAddress, amounts sdk.Coins) error {
	if err := s.App.BankKeeper.MintCoins(ctx, minttypes.ModuleName, amounts); err != nil {
		return err
	}

	return s.App.BankKeeper.SendCoinsFromModuleToAccount(ctx, minttypes.ModuleName, addr, amounts)
}

func TestKeeperTestSuite(t *testing.T) {
	suite.Run(t, new(IntegrationTestSuite))
}
