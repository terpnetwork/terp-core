//go:build v64

package v6_4_test

import (
	"testing"
	"time"

	"cosmossdk.io/core/appmodule"
	"cosmossdk.io/core/header"
	"cosmossdk.io/math"
	addresscodec "github.com/cosmos/cosmos-sdk/codec/address"
	sdk "github.com/cosmos/cosmos-sdk/types"
	banktypes "github.com/cosmos/cosmos-sdk/x/bank/types"
	"github.com/cosmos/cosmos-sdk/x/upgrade"
	upgradetypes "github.com/cosmos/cosmos-sdk/x/upgrade/types"
	ibcexported "github.com/cosmos/ibc-go/v11/modules/core/exported"
	ics23 "github.com/cosmos/ics23/go"
	"github.com/stretchr/testify/suite"

	"github.com/cosmos/iavl"
	dbm "github.com/cosmos/iavl/db"

	"github.com/terpnetwork/terp-core/v6/app/iavlhash"
	"github.com/terpnetwork/terp-core/v6/app/keepers"
	"github.com/terpnetwork/terp-core/v6/app/testutils"
	v64 "github.com/terpnetwork/terp-core/v6/app/upgrades/v6_4"
)

const v64UpgradeHeight = int64(8)

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

func (s *UpgradeTestSuite) TestKeepersOnDestNoRename() {
	s.SetupTest()
	s.Require().True(keepers.KeepersOnDest)
	s.Require().Nil(s.App.GetKey("bank"), "live SHA-256 bank must not be mounted")
	s.Require().NotNil(s.App.GetKey(iavlhash.BankB3))
	s.Require().Equal(iavlhash.BankB3, s.App.KeeperKey(banktypes.StoreKey).Name())
	s.Require().NotNil(s.App.GetKey(ibcexported.StoreKey))
	s.Require().Nil(s.App.GetKey("b3-ibc"))
	s.Require().Equal("sha256", iavlhash.AlgorithmName("ibc"))
	s.Require().Equal("blake3", iavlhash.AlgorithmName(iavlhash.BankB3))
}

func (s *UpgradeTestSuite) TestHandlerKeepsDestAndIBC() {
	s.SetupTest()
	s.FundAcc(s.TestAccs[0], sdk.NewCoins(sdk.NewCoin(sdk.DefaultBondDenom, math.NewInt(1_000_000))))
	s.scheduleUpgrade()
	s.Require().NotPanics(func() {
		_, err := s.preModule.PreBlock(s.Ctx)
		s.Require().NoError(err)
	})
	s.Require().NotNil(s.App.GetKey(iavlhash.BankB3))
	s.Require().Nil(s.App.GetKey("bank"))
	s.Require().NotNil(s.App.GetKey(ibcexported.StoreKey))
	_, err := s.App.UpgradeKeeper.GetUpgradePlan(s.Ctx)
	s.Require().Error(err, "v6.4 must not arm a further plan")

	s.assertCopiedKVProof(iavlhash.BankB3, ics23.HashOp_BLAKE3)
	s.assertCopiedKVProof(ibcexported.StoreKey, ics23.HashOp_SHA256)
}

func (s *UpgradeTestSuite) scheduleUpgrade() {
	s.Ctx = s.Ctx.WithBlockHeight(v64UpgradeHeight - 1)
	plan := upgradetypes.Plan{Name: v64.UpgradeName, Height: v64UpgradeHeight}
	s.Require().NoError(s.App.UpgradeKeeper.ScheduleUpgrade(s.Ctx, plan))
	s.Ctx = s.Ctx.WithHeaderInfo(header.Info{Height: v64UpgradeHeight, Time: s.Ctx.BlockTime().Add(time.Second)}).
		WithBlockHeight(v64UpgradeHeight)
}

func (s *UpgradeTestSuite) dumpStore(name string) map[string][]byte {
	key := s.App.GetKey(name)
	s.Require().NotNil(key, name)
	it := s.Ctx.KVStore(key).Iterator(nil, nil)
	defer it.Close()
	out := map[string][]byte{}
	for ; it.Valid(); it.Next() {
		out[string(it.Key())] = append([]byte(nil), it.Value()...)
	}
	return out
}

func (s *UpgradeTestSuite) assertCopiedKVProof(storeName string, want ics23.HashOp) {
	keys := s.dumpStore(storeName)
	s.Require().NotEmpty(keys, storeName)
	tree := iavl.NewMutableTree(dbm.NewMemDB(), 0, false, iavl.NewNopLogger(), iavl.HasherOptionForStore(storeName))
	var firstK, firstV []byte
	for k, v := range keys {
		if len(v) == 0 {
			continue
		}
		_, err := tree.Set([]byte(k), v)
		s.Require().NoError(err)
		if firstK == nil {
			firstK, firstV = []byte(k), v
		}
	}
	_, _, err := tree.SaveVersion()
	s.Require().NoError(err)
	proof, err := tree.GetMembershipProof(firstK)
	s.Require().NoError(err)
	hop, err := iavlhash.ProofHashOp(proof)
	s.Require().NoError(err)
	s.Require().Equal(want, hop, storeName)
	s.Require().NoError(iavlhash.VerifyExclusive(storeName, tree.Hash(), proof, firstK, firstV))
}
