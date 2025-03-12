package keeper_test

import (
	"testing"

	"cosmossdk.io/math"
	"github.com/stretchr/testify/suite"

	"github.com/cosmos/cosmos-sdk/client"
	sdk "github.com/cosmos/cosmos-sdk/types"

	"github.com/terpnetwork/terp-core/v4/app"
	"github.com/terpnetwork/terp-core/v4/app/apptesting"
	ap "github.com/terpnetwork/terp-core/v4/app/params"
	"github.com/terpnetwork/terp-core/v4/x/globalfee/types"
)

type KeeperTestSuite struct {
	apptesting.KeeperTestHelper

	clientCtx   client.Context
	queryClient types.QueryClient
}

func TestKeeperTestSuite(t *testing.T) {
	suite.Run(t, new(KeeperTestSuite))
}

func (s *KeeperTestSuite) SetupTest(isCheckTx bool) {
	s.Setup()
	s.queryClient = types.NewQueryClient(s.QueryHelper)
	encConfig := app.MakeEncodingConfig()
	s.clientCtx = client.Context{}.
		WithInterfaceRegistry(encConfig.InterfaceRegistry).
		WithTxConfig(encConfig.TxConfig).
		WithLegacyAmino(encConfig.Amino).
		WithCodec(encConfig.Marshaler)

	// Mint some assets to the accounts.
	for _, acc := range s.TestAccs {
		s.FundAcc(acc,
			sdk.NewCoins(
				sdk.NewCoin(sdk.DefaultBondDenom, math.NewInt(10000000000)),
				sdk.NewCoin(ap.BaseCoinUnit, math.NewInt(100000000000000000)), // Needed for pool creation fee
				sdk.NewCoin("uion", math.NewInt(10000000)),
				sdk.NewCoin("atom", math.NewInt(10000000)),
				sdk.NewCoin("ust", math.NewInt(10000000)),
				sdk.NewCoin("foo", math.NewInt(10000000)),
				sdk.NewCoin("bar", math.NewInt(10000000)),
			))
	}
}
