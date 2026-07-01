package v6_test

import (
	"testing"
	"time"

	"github.com/stretchr/testify/suite"

	"cosmossdk.io/core/appmodule"
	"cosmossdk.io/core/header"
	upgradetypes "cosmossdk.io/x/upgrade/types"

	testutils "github.com/terpnetwork/terp-core/v5/app/testutils"
	v6 "github.com/terpnetwork/terp-core/v5/app/upgrades/v6"
	"github.com/terpnetwork/terp-core/v5/x/tokenfactory/types"

	"cosmossdk.io/x/upgrade"

	addresscodec "github.com/cosmos/cosmos-sdk/codec/address"
)

const (
	v6UpgradeHeight = int64(10)
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
	s.PrepareTokenFactoryParams()
	// Run the upgrade
	dummyUpgrade(s)
	s.Require().NotPanics(func() {
		_, err := s.preModule.PreBlock(s.Ctx)
		s.Require().NoError(err)
	})

	s.ExecuteTokenFactoryParamsTest()
}

func dummyUpgrade(s *UpgradeTestSuite) {
	s.Ctx = s.Ctx.WithBlockHeight(v6UpgradeHeight - 1)
	plan := upgradetypes.Plan{Name: v6.Upgrade.UpgradeName, Height: v6UpgradeHeight}
	err := s.App.UpgradeKeeper.ScheduleUpgrade(s.Ctx, plan)
	s.Require().NoError(err)
	_, err = s.App.UpgradeKeeper.GetUpgradePlan(s.Ctx)
	s.Require().NoError(err)

	s.Ctx = s.Ctx.WithHeaderInfo(header.Info{Height: v6UpgradeHeight, Time: s.Ctx.BlockTime().Add(time.Second)}).WithBlockHeight(v6UpgradeHeight)
}

func (s *UpgradeTestSuite) PrepareTokenFactoryParams() {
	// set nothing in params, require error
	// _, err := s.App.TokenFactoryKeeper.Params(s.Ctx, &types.QueryParamsRequest{})
	// s.Require().Error(err)
}

func (s *UpgradeTestSuite) ExecuteTokenFactoryParamsTest() {
	consParams, err := s.App.TokenFactoryKeeper.Params(s.Ctx, &types.QueryParamsRequest{})
	s.Require().Equal(consParams.Params, types.DefaultParams())
	s.Require().NoError(err)
}
