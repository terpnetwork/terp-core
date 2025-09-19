package v5_test

import (
	"testing"
	"time"

	cmttypes "github.com/cometbft/cometbft/types"
	"github.com/stretchr/testify/suite"

	"cosmossdk.io/core/appmodule"
	"cosmossdk.io/core/header"
	upgradetypes "cosmossdk.io/x/upgrade/types"

	testutils "github.com/terpnetwork/terp-core/v5/app/testutil"
	v5 "github.com/terpnetwork/terp-core/v5/app/upgrades/v5"

	"cosmossdk.io/x/upgrade"

	addresscodec "github.com/cosmos/cosmos-sdk/codec/address"
)

const (
	v5UpgradeHeight = int64(10)
)

var (
// consAddr = sdk.ConsAddress(sdk.AccAddress([]byte("addr1_______________")))
)

type UpgradeTestSuite struct {
	testutils.KeeperTestHelper
	preModule appmodule.HasPreBlocker
}

func TestUpgradeTestSuite(t *testing.T) {
	suite.Run(t, new(UpgradeTestSuite))
}

func (s *UpgradeTestSuite) TestUpgrade() {
	s.Setup()
	s.preModule = upgrade.NewAppModule(s.App.UpgradeKeeper, addresscodec.NewBech32Codec("terp"))

	// pre upgrade
	s.PrepareVoteExtensionsEnableHeightTest()

	// Run the upgrade
	dummyUpgrade(s)
	s.Require().NotPanics(func() {
		_, err := s.preModule.PreBlock(s.Ctx)
		s.Require().NoError(err)
	})

	// post upgrade
	s.ExecuteVoteExtensionsEnableHeightTest()
}

func dummyUpgrade(s *UpgradeTestSuite) {
	s.Ctx = s.Ctx.WithBlockHeight(v5UpgradeHeight - 1)
	plan := upgradetypes.Plan{Name: v5.Upgrade.UpgradeName, Height: v5UpgradeHeight}
	err := s.App.UpgradeKeeper.ScheduleUpgrade(s.Ctx, plan)
	s.Require().NoError(err)
	_, err = s.App.UpgradeKeeper.GetUpgradePlan(s.Ctx)
	s.Require().NoError(err)

	s.Ctx = s.Ctx.WithHeaderInfo(header.Info{Height: v5UpgradeHeight, Time: s.Ctx.BlockTime().Add(time.Second)}).WithBlockHeight(v5UpgradeHeight)
}

func (s *UpgradeTestSuite) PrepareVoteExtensionsEnableHeightTest() {
	defaultConsensusParams := cmttypes.DefaultConsensusParams().ToProto()

	err := s.App.ConsensusParamsKeeper.ParamsStore.Set(s.Ctx, defaultConsensusParams)
	s.Require().NoError(err)
}

func (s *UpgradeTestSuite) ExecuteVoteExtensionsEnableHeightTest() {
	consParams, err := s.App.ConsensusParamsKeeper.ParamsStore.Get(s.Ctx)
	s.Require().NoError(err)
	s.Require().Equal(consParams.Abci.VoteExtensionsEnableHeight, int64(10))
}

// func (s *UpgradeTestSuite) PrepareCostPerByteTest() {
// 	accountParams := s.App.AccountKeeper.GetParams(s.Ctx)
// 	accountParams.TxSizeCostPerByte = 0
// 	s.App.AccountKeeper.Params.Set(s.Ctx, accountParams)
// }

// func (s *UpgradeTestSuite) ExecuteCostPerByteTest() {
// 	accountParams := s.App.AccountKeeper.GetParams(s.Ctx)
// 	s.Require().Equal(accountParams.TxSizeCostPerByte, v5.CostPerByte)
// }
