package v6_2_test

import (
	"testing"
	"time"

	"cosmossdk.io/core/appmodule"
	"cosmossdk.io/core/header"
	"cosmossdk.io/math"
	addresscodec "github.com/cosmos/cosmos-sdk/codec/address"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/x/upgrade"
	upgradetypes "github.com/cosmos/cosmos-sdk/x/upgrade/types"
	ibcexported "github.com/cosmos/ibc-go/v11/modules/core/exported"
	"github.com/stretchr/testify/require"
	"github.com/stretchr/testify/suite"

	"github.com/terpnetwork/terp-core/v6/app/iavlhash"
	"github.com/terpnetwork/terp-core/v6/app/testutils"
	v62 "github.com/terpnetwork/terp-core/v6/app/upgrades/v6_2"
)

const v62UpgradeHeight = int64(8)

type UpgradeTestSuite struct {
	testutils.KeeperTestHelper
	preModule appmodule.HasPreBlocker
}

func TestUpgradeTestSuite(t *testing.T) {
	suite.Run(t, new(UpgradeTestSuite))
}

func (s *UpgradeTestSuite) SetupTest() {
	s.Setup()
	s.preModule = upgrade.NewAppModule(s.App.UpgradeKeeper, addresscodec.NewBech32Codec("terp"))
}

func TestNoRenameOntoExistingKeeperNames(t *testing.T) {
	require.Empty(t, v62.Upgrade.StoreUpgrades.Renamed)
	require.Empty(t, v62.Upgrade.StoreUpgrades.Added)
	require.Equal(t, "v6.2", v62.UpgradeName)
}

func (s *UpgradeTestSuite) TestNoB3SuffixMounted() {
	s.SetupTest()
	s.Require().Nil(s.App.GetKey(iavlhash.BankB3), "post-B binary must not mount b3-bank")
	s.Require().Nil(s.App.GetKey(iavlhash.StakingB3))
	s.Require().Nil(s.App.GetKey(iavlhash.AuthB3))
	s.Require().NotNil(s.App.GetKey("bank"))
	s.Require().NotNil(s.App.GetKey("staking"))
	s.Require().NotNil(s.App.GetKey("acc"))
	s.Require().NotNil(s.App.GetKey(ibcexported.StoreKey))
}

func (s *UpgradeTestSuite) TestHandlerKeepsBankAndIBC() {
	s.SetupTest()
	s.FundAcc(s.TestAccs[0], sdk.NewCoins(sdk.NewCoin(sdk.DefaultBondDenom, math.NewInt(1_000_000))))
	s.scheduleUpgrade()
	s.Require().NotPanics(func() {
		_, err := s.preModule.PreBlock(s.Ctx)
		s.Require().NoError(err)
	})
	s.Require().NotNil(s.App.GetKey("bank"))
	s.Require().NotNil(s.App.GetKey(ibcexported.StoreKey))
	s.Require().Nil(s.App.GetKey("b3-ibc"))
}

func (s *UpgradeTestSuite) scheduleUpgrade() {
	s.Ctx = s.Ctx.WithBlockHeight(v62UpgradeHeight - 1)
	plan := upgradetypes.Plan{Name: v62.UpgradeName, Height: v62UpgradeHeight}
	s.Require().NoError(s.App.UpgradeKeeper.ScheduleUpgrade(s.Ctx, plan))
	s.Ctx = s.Ctx.WithHeaderInfo(header.Info{Height: v62UpgradeHeight, Time: s.Ctx.BlockTime().Add(time.Second)}).
		WithBlockHeight(v62UpgradeHeight)
}
