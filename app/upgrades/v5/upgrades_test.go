package v5_test

import (
	"testing"
	"time"

	cmttypes "github.com/cometbft/cometbft/types"
	"github.com/stretchr/testify/suite"

	"cosmossdk.io/core/appmodule"
	"cosmossdk.io/core/header"
	upgradetypes "cosmossdk.io/x/upgrade/types"
	sdk "github.com/cosmos/cosmos-sdk/types"

	"github.com/terpnetwork/terp-core/v4/app/apptesting"
	v5 "github.com/terpnetwork/terp-core/v4/app/upgrades/v5"

	"cosmossdk.io/x/upgrade"

	addresscodec "github.com/cosmos/cosmos-sdk/codec/address"
)

const (
	v5UpgradeHeight = int64(10)
)

var (
	consAddr = sdk.ConsAddress(sdk.AccAddress([]byte("addr1_______________")))
	denomA   = "denomA"
	denomB   = "denomB"
	denomC   = "denomC"
	denomD   = "denomD"
)

type UpgradeTestSuite struct {
	apptesting.KeeperTestHelper
	preModule appmodule.HasPreBlocker
}

func TestUpgradeTestSuite(t *testing.T) {
	suite.Run(t, new(UpgradeTestSuite))
}

func (s *UpgradeTestSuite) TestUpgrade() {
	s.Setup()
	s.preModule = upgrade.NewAppModule(s.App.AppKeepers.UpgradeKeeper, addresscodec.NewBech32Codec("terp"))

	s.PrepareChangeBlockParamsTest()
	s.PrepareCostPerByteTest()

	// Run the upgrade
	dummyUpgrade(s)
	s.Require().NotPanics(func() {
		_, err := s.preModule.PreBlock(s.Ctx)
		s.Require().NoError(err)
	})

	// s.ExecuteTradingPairTakerFeeTest()
	// s.ExecuteIncreaseUnauthenticatedGasTest()
	s.ExecuteChangeBlockParamsTest()
	// s.ExecuteCostPerByteTest()
}

func dummyUpgrade(s *UpgradeTestSuite) {
	s.Ctx = s.Ctx.WithBlockHeight(v5UpgradeHeight - 1)
	plan := upgradetypes.Plan{Name: v5.Upgrade.UpgradeName, Height: v5UpgradeHeight}
	err := s.App.AppKeepers.UpgradeKeeper.ScheduleUpgrade(s.Ctx, plan)
	s.Require().NoError(err)
	_, err = s.App.AppKeepers.UpgradeKeeper.GetUpgradePlan(s.Ctx)
	s.Require().NoError(err)

	s.Ctx = s.Ctx.WithHeaderInfo(header.Info{Height: v5UpgradeHeight, Time: s.Ctx.BlockTime().Add(time.Second)}).WithBlockHeight(v5UpgradeHeight)
}

func (s *UpgradeTestSuite) PrepareChangeBlockParamsTest() {
	defaultConsensusParams := cmttypes.DefaultConsensusParams().ToProto()
	defaultConsensusParams.Block.MaxBytes = 1
	defaultConsensusParams.Block.MaxGas = 1
	// defaultConsensusParams.Abci.VoteExtensionsEnableHeight = 1
	s.App.AppKeepers.ConsensusParamsKeeper.ParamsStore.Set(s.Ctx, defaultConsensusParams)
}

func (s *UpgradeTestSuite) ExecuteChangeBlockParamsTest() {
	consParams, err := s.App.AppKeepers.ConsensusParamsKeeper.ParamsStore.Get(s.Ctx)
	s.Require().NoError(err)
	// s.Require().Equal(consParams.Block.MaxBytes, v5.BlockMaxBytes)
	// s.Require().Equal(consParams.Block.MaxGas, v5.BlockMaxGas)
	s.Require().Equal(consParams.Abci.VoteExtensionsEnableHeight, 1)
}

func (s *UpgradeTestSuite) PrepareCostPerByteTest() {
	accountParams := s.App.AppKeepers.AccountKeeper.GetParams(s.Ctx)
	accountParams.TxSizeCostPerByte = 0
	s.App.AppKeepers.AccountKeeper.Params.Set(s.Ctx, accountParams)
}

// func (s *UpgradeTestSuite) ExecuteCostPerByteTest() {
// 	accountParams := s.App.AppKeepers.AccountKeeper.GetParams(s.Ctx)
// 	s.Require().Equal(accountParams.TxSizeCostPerByte, v5.CostPerByte)
// }
