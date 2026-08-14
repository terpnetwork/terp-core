package v6_test

import (
	"testing"
	"time"

	wasmtypes "github.com/CosmWasm/wasmd/x/wasm/types"
	"github.com/stretchr/testify/suite"

	"cosmossdk.io/core/appmodule"
	"cosmossdk.io/core/header"

	addresscodec "github.com/cosmos/cosmos-sdk/codec/address"
	"github.com/cosmos/cosmos-sdk/x/upgrade"
	upgradetypes "github.com/cosmos/cosmos-sdk/x/upgrade/types"

	testutils "github.com/terpnetwork/terp-core/v6/app/testutils"
	v6 "github.com/terpnetwork/terp-core/v6/app/upgrades/v6"
)

const v6UpgradeHeight = int64(10)

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

	// Pre-upgrade: keeper is live (genesis permission may be unspecified or everybody).
	pre := s.App.WasmKeeper.GetParams(s.Ctx)
	s.Require().NotNil(pre.CircuitUploadAccess)

	s.scheduleUpgrade()
	s.Require().NotPanics(func() {
		_, err := s.preModule.PreBlock(s.Ctx)
		s.Require().NoError(err)
	})

	s.assertUpgradeApplied()
}

func (s *UpgradeTestSuite) scheduleUpgrade() {
	s.Ctx = s.Ctx.WithBlockHeight(v6UpgradeHeight - 1)
	plan := upgradetypes.Plan{Name: v6.UpgradeName, Height: v6UpgradeHeight}
	s.Require().NoError(s.App.UpgradeKeeper.ScheduleUpgrade(s.Ctx, plan))
	got, err := s.App.UpgradeKeeper.GetUpgradePlan(s.Ctx)
	s.Require().NoError(err)
	s.Require().Equal(v6.UpgradeName, got.Name)

	s.Ctx = s.Ctx.WithHeaderInfo(header.Info{Height: v6UpgradeHeight, Time: s.Ctx.BlockTime().Add(time.Second)}).
		WithBlockHeight(v6UpgradeHeight)
}

func (s *UpgradeTestSuite) assertUpgradeApplied() {
	// Handler consumed the plan at this height.
	_, err := s.App.UpgradeKeeper.GetUpgradePlan(s.Ctx)
	s.Require().Error(err, "upgrade plan should be cleared after v6 runs")

	// Circuit pin/store is locked down.
	params := s.App.WasmKeeper.GetParams(s.Ctx)
	s.Require().Equal(wasmtypes.AllowNobody.Permission, params.CircuitUploadAccess.Permission)

	// Stores listed in v6.StoreUpgrades.Deleted must not come back.
	keys := s.App.GetKVStoreKey()
	_, hasGroup := keys["group"]
	_, hasNFT := keys["nft"]
	s.Require().False(hasGroup, "group store must stay deleted")
	s.Require().False(hasNFT, "nft store must stay deleted")

	// Custom modules that survive the bump remain wired.
	s.Require().NotNil(s.App.TokenFactoryKeeper)
	s.Require().NotNil(s.App.IBCKeeper)
	s.Require().NotNil(s.App.WasmKeeper)
}
