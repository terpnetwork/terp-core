package v6_1_test

import (
	"bytes"
	"testing"
	"time"

	"cosmossdk.io/core/appmodule"
	"cosmossdk.io/core/header"
	"cosmossdk.io/math"
	addresscodec "github.com/cosmos/cosmos-sdk/codec/address"
	storetypes "github.com/cosmos/cosmos-sdk/store/v2/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/x/upgrade"
	upgradetypes "github.com/cosmos/cosmos-sdk/x/upgrade/types"
	ibcexported "github.com/cosmos/ibc-go/v11/modules/core/exported"
	"github.com/stretchr/testify/suite"

	"github.com/cosmos/cosmos-sdk/codec"
	"github.com/cosmos/cosmos-sdk/std"

	"github.com/terpnetwork/terp-core/v6/app/iavlhash"
	"github.com/terpnetwork/terp-core/v6/app/keepers"
	"github.com/terpnetwork/terp-core/v6/app/testutils"
	v61 "github.com/terpnetwork/terp-core/v6/app/upgrades/v6_1"
	tokenfactorytypes "github.com/terpnetwork/terp-core/v6/x/tokenfactory/types"
)

const v61UpgradeHeight = int64(5)

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

// TestUpgrade runs the v6.1 handler the same way v6/v520 do (schedule plan +
// PreBlock) and checks IAVL dual-store copy soundness: dest trees get the src
// KV (new inner nodes / working hash), IBC is untouched, last-commit is not
// the copied root until Commit.
func (s *UpgradeTestSuite) TestUpgrade() {
	s.SetupTest()

	s.FundAcc(s.TestAccs[0], sdk.NewCoins(sdk.NewCoin(sdk.DefaultBondDenom, math.NewInt(1_000_000))))

	type snap struct {
		name     string
		src, dst string
		keys     map[string][]byte
		srcHash  []byte
		dstHash  []byte
		dstLast  []byte
	}
	snaps := make([]snap, 0, len(iavlhash.DualStorePairs()))
	for _, p := range iavlhash.DualStorePairs() {
		snaps = append(snaps, snap{
			name:    p[0] + "->" + p[1],
			src:     p[0],
			dst:     p[1],
			keys:    s.dumpStore(p[0]),
			srcHash: append([]byte(nil), s.commitStore(p[0]).WorkingHash()...),
			dstHash: append([]byte(nil), s.commitStore(p[1]).WorkingHash()...),
			dstLast: append([]byte(nil), s.commitStore(p[1]).LastCommitID().Hash...),
		})
	}
	s.Require().Greater(len(snaps[0].keys), 0, "bank must have genesis+funded keys to copy")

	s.Require().NotNil(s.App.GetKey(ibcexported.StoreKey), "IBC store must remain mounted")

	s.scheduleUpgrade()
	s.Require().NotPanics(func() {
		_, err := s.preModule.PreBlock(s.Ctx)
		s.Require().NoError(err)
	})

	// Handler writes go to the block cache. Flush so IAVL WorkingHash sees new nodes.
	if cms, ok := s.Ctx.MultiStore().(storetypes.CacheMultiStore); ok {
		cms.Write()
	}

	_, err := s.App.UpgradeKeeper.GetUpgradePlan(s.Ctx)
	s.Require().Error(err, "upgrade plan should be cleared after v6.1 runs")

	for _, sn := range snaps {
		got := s.dumpStore(sn.dst)
		s.Require().Equal(len(sn.keys), len(got), "%s: dest key count", sn.name)
		for k, v := range sn.keys {
			s.Require().Equal(v, got[k], "%s: dest missing or mismatch key %q", sn.name, k)
		}

		dstWorking := s.commitStore(sn.dst).WorkingHash()
		s.Require().Len(dstWorking, 32, "%s: dest IAVL working hash", sn.name)
		s.Require().False(bytes.Equal(dstWorking, sn.dstHash),
			"%s: dest working hash must change as inner nodes are rebuilt", sn.name)

		// KV copy at upgrade height creates new node versions, so dest root
		// is not the src tree's root even with the same hasher.
		s.Require().False(bytes.Equal(dstWorking, sn.srcHash),
			"%s: dest working hash must not be src's (rebuilt internals)", sn.name)
		s.Require().False(bytes.Equal(dstWorking, sn.dstLast),
			"%s: unsound if pre-copy LastCommitID is treated as the copied root", sn.name)
		s.Require().NotEqual("ibc", sn.src)
		s.Require().NotEqual("ibc", sn.dst)
	}

	s.Require().Nil(s.App.GetKey("b3-ibc"), "no IBC dest tree")
	s.Require().NotNil(s.commitStore(ibcexported.StoreKey), "IBC IAVL store still mounted")
}

func (s *UpgradeTestSuite) TestLegacySubspaceCopiedIntoModuleStore() {
	s.SetupTest()
	s.Require().NotNil(s.App.GetKey(keepers.LegacyParamsStoreKey), "params store must stay mounted for the copy")

	tfKey := s.App.GetKey(tokenfactorytypes.StoreKey)
	s.Ctx.KVStore(tfKey).Delete(tokenfactorytypes.ParamsKey)

	amino := codec.NewLegacyAmino()
	std.RegisterLegacyAminoCodec(amino)
	want := sdk.NewCoins(sdk.NewInt64Coin("uterp", 42))
	bz, err := amino.MarshalJSON(want)
	s.Require().NoError(err)
	gas := uint64(7)
	gbz, err := amino.MarshalJSON(gas)
	s.Require().NoError(err)

	ps := s.Ctx.KVStore(s.App.GetKey(keepers.LegacyParamsStoreKey))
	ps.Set(append([]byte("tokenfactory/"), tokenfactorytypes.KeyDenomCreationFee...), bz)
	ps.Set(append([]byte("tokenfactory/"), tokenfactorytypes.KeyDenomCreationGasConsume...), gbz)

	s.scheduleUpgrade()
	s.Require().NotPanics(func() {
		_, err := s.preModule.PreBlock(s.Ctx)
		s.Require().NoError(err)
	})

	got := s.App.TokenFactoryKeeper.GetParams(s.Ctx)
	s.Require().True(want.Equal(got.DenomCreationFee), "subspace fee must win over defaults: got %s", got.DenomCreationFee)
	s.Require().Equal(uint64(7), got.DenomCreationGasConsume)

	it := s.Ctx.KVStore(s.App.GetKey(keepers.LegacyParamsStoreKey)).Iterator(nil, nil)
	defer it.Close()
	s.Require().False(it.Valid(), "legacy params keys must be wiped after copy")
}

func (s *UpgradeTestSuite) scheduleUpgrade() {
	s.Ctx = s.Ctx.WithBlockHeight(v61UpgradeHeight - 1)
	plan := upgradetypes.Plan{Name: v61.UpgradeName, Height: v61UpgradeHeight}
	s.Require().NoError(s.App.UpgradeKeeper.ScheduleUpgrade(s.Ctx, plan))
	got, err := s.App.UpgradeKeeper.GetUpgradePlan(s.Ctx)
	s.Require().NoError(err)
	s.Require().Equal(v61.UpgradeName, got.Name)

	s.Ctx = s.Ctx.WithHeaderInfo(header.Info{Height: v61UpgradeHeight, Time: s.Ctx.BlockTime().Add(time.Second)}).
		WithBlockHeight(v61UpgradeHeight)
}

func (s *UpgradeTestSuite) commitStore(name string) storetypes.CommitKVStore {
	key := s.App.GetKey(name)
	s.Require().NotNil(key, name)
	st := s.App.CommitMultiStore().GetStore(key)
	s.Require().NotNil(st, name)
	ckv, ok := st.(storetypes.CommitKVStore)
	s.Require().True(ok, "%s is not CommitKVStore", name)
	return ckv
}

func (s *UpgradeTestSuite) dumpStore(name string) map[string][]byte {
	key := s.App.GetKey(name)
	s.Require().NotNil(key, name)
	it := s.Ctx.KVStore(key).Iterator(nil, nil)
	defer it.Close()
	out := map[string][]byte{}
	for ; it.Valid(); it.Next() {
		v := append([]byte(nil), it.Value()...)
		out[string(it.Key())] = v
	}
	return out
}
