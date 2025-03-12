package keeper_test

import (
	"context"
	"testing"
	"time"

	wasmkeeper "github.com/CosmWasm/wasmd/x/wasm/keeper"
	wasmtypes "github.com/CosmWasm/wasmd/x/wasm/types"
	"github.com/stretchr/testify/suite"

	"github.com/cosmos/cosmos-sdk/baseapp"
	sdk "github.com/cosmos/cosmos-sdk/types"
	minttypes "github.com/cosmos/cosmos-sdk/x/mint/types"

	"github.com/terpnetwork/terp-core/v4/app/apptesting"
	"github.com/terpnetwork/terp-core/v4/x/feeshare/keeper"
	"github.com/terpnetwork/terp-core/v4/x/feeshare/types"
)

// BankKeeper defines the expected interface needed to retrieve account balances.
type BankKeeper interface {
	MintCoins(ctx context.Context, moduleName string, amt sdk.Coins) error
	SendCoins(ctx context.Context, fromAddr, toAddr sdk.AccAddress, amt sdk.Coins) error
	SendCoinsFromAccountToModule(ctx context.Context, senderAddr sdk.AccAddress, recipientModule string, amt sdk.Coins) error
	SendCoinsFromModuleToAccount(ctx context.Context, senderModule string, recipientAddr sdk.AccAddress, amt sdk.Coins) error
	SendCoinsFromModuleToModule(ctx context.Context, senderModule, recipientModule string, amt sdk.Coins) error
}

type KeeperTestSuite struct {
	apptesting.KeeperTestHelper

	queryClient       types.QueryClient
	feeShareMsgServer types.MsgServer
	wasmMsgServer     wasmtypes.MsgServer
}

func (s *KeeperTestSuite) SetupTest() {
	s.Setup()
	s.Ctx = s.Ctx.WithBlockTime(s.Ctx.BlockTime().Add(time.Hour))

	queryHelper := baseapp.NewQueryServerTestHelper(s.Ctx, s.App.InterfaceRegistry())
	types.RegisterQueryServer(queryHelper, keeper.NewQuerier(s.App.FeeShareKeeper))

	s.queryClient = types.NewQueryClient(queryHelper)

	s.feeShareMsgServer = s.App.FeeShareKeeper
	s.wasmMsgServer = wasmkeeper.NewMsgServerImpl(&s.App.WasmKeeper)
}

func (s *KeeperTestSuite) FundAccount(ctx sdk.Context, addr sdk.AccAddress, amounts sdk.Coins) error {
	if err := s.App.BankKeeper.MintCoins(ctx, minttypes.ModuleName, amounts); err != nil {
		return err
	}

	return s.App.BankKeeper.SendCoinsFromModuleToAccount(ctx, minttypes.ModuleName, addr, amounts)
}

func TestKeeperTestSuite(t *testing.T) {
	suite.Run(t, new(KeeperTestSuite))
}
