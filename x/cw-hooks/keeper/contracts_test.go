package keeper_test

import (
	sdkmath "cosmossdk.io/math"

	storetypes "github.com/cosmos/cosmos-sdk/store/v2/types"
	"github.com/cosmos/cosmos-sdk/testutil/testdata"
	sdk "github.com/cosmos/cosmos-sdk/types"

	"github.com/terpnetwork/terp-core/v6/x/cw-hooks/types"
)

func (s *KeeperTestSuite) TestExecuteMessageOnContractsSudoFailureIsLiveness() {
	s.SetupTest()
	_, _, sender := testdata.KeyTestPubAddr()
	s.FundAcc(sender, sdk.NewCoins(sdk.NewCoin("stake", sdkmath.NewInt(1_000_000))))

	contractAddress := s.InstantiateContract(sender.String(), "", wasmContract)
	_, err := s.msgServer.RegisterStaking(s.Ctx, &types.MsgRegisterStaking{
		ContractAddress: contractAddress,
		RegisterAddress: sender.String(),
	})
	s.Require().NoError(err)

	k := s.App.CwHooksKeeper
	invalidSudo := []byte(`{"not_a_hook":{}}`)

	s.Run("sudo error does not fail and bills parent", func() {
		ctx := s.Ctx.WithGasMeter(storetypes.NewGasMeter(10_000_000))
		before := ctx.GasMeter().GasConsumed()

		err := k.ExecuteMessageOnContracts(ctx, types.KeyPrefixStaking, invalidSudo)
		s.Require().NoError(err)
		s.Require().GreaterOrEqual(ctx.GasMeter().GasConsumed()-before, uint64(60_000))
	})

	s.Run("inner OOG does not fail and bills parent", func() {
		s.Require().NoError(k.SetParams(s.Ctx, types.NewParams(10_000)))
		ctx := s.Ctx.WithGasMeter(storetypes.NewGasMeter(10_000_000))
		before := ctx.GasMeter().GasConsumed()

		err := k.ExecuteMessageOnContracts(ctx, types.KeyPrefixStaking, invalidSudo)
		s.Require().NoError(err)
		s.Require().GreaterOrEqual(ctx.GasMeter().GasConsumed()-before, uint64(10_000))
		s.Require().NoError(k.SetParams(s.Ctx, types.DefaultParams()))
	})
}
