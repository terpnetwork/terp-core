//go:build !v64 && !v63pre

package v6_3_test

import (
	"bytes"
	"encoding/json"
	"strings"
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
	ics23 "github.com/cosmos/ics23/go"
	"github.com/stretchr/testify/suite"

	"github.com/cosmos/iavl"
	dbm "github.com/cosmos/iavl/db"

	terpiavl "github.com/terpnetwork/terp-core/v6/app/iavl"
	"github.com/terpnetwork/terp-core/v6/app/keepers"
	"github.com/terpnetwork/terp-core/v6/app/testutils"
	v63 "github.com/terpnetwork/terp-core/v6/app/upgrades/v6_3"
)

const v63UpgradeHeight = int64(5)

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

func (s *UpgradeTestSuite) TestUpgradeCopiesDestArmsV64() {
	s.SetupTest()
	if s.App.GetKey(terpiavl.DestStores()[0]) == nil {
		s.T().Skip("this ELF does not mount dest trees")
	}
	s.FundAcc(s.TestAccs[0], sdk.NewCoins(sdk.NewCoin(sdk.DefaultBondDenom, math.NewInt(1_000_000))))

	srcBank := s.dumpStore("bank")
	s.Require().Greater(len(srcBank), 0, "bank must have genesis+funded keys to copy")
	s.Require().NotNil(s.App.GetKey(ibcexported.StoreKey))
	s.Require().Nil(s.App.GetKey("b3-ibc"))

	s.scheduleUpgrade()
	s.Require().NotPanics(func() {
		_, err := s.preModule.PreBlock(s.Ctx)
		s.Require().NoError(err)
	})

	for _, p := range terpiavl.DualStorePairs() {
		got := s.dumpStore(p[1])
		live := s.dumpStore(p[0])
		s.Require().Equal(len(live), len(got), "%s: dest key count vs src", p[0])
		for k, v := range live {
			s.Require().Equal(v, got[k], "%s dest mismatch key %q", p[0], k)
		}
	}

	_, err := s.App.EndBlocker(s.Ctx)
	s.Require().NoError(err)
	if cms, ok := s.Ctx.MultiStore().(storetypes.CacheMultiStore); ok {
		cms.Write()
	}

	plan, err := s.App.UpgradeKeeper.GetUpgradePlan(s.Ctx)
	s.Require().NoError(err)
	s.Require().Equal(v63.NextUpgradeName, plan.Name)
	s.Require().Equal(v63UpgradeHeight+v63.NextUpgradeGap, plan.Height)
	s.Require().Equal(v63.NextUpgradeInfo, plan.Info)

	s.Require().NotNil(s.commitStore(ibcexported.StoreKey))
	srcHash := s.commitStore("bank").WorkingHash()
	dstHash := s.commitStore("b3-bank").WorkingHash()
	s.Require().False(bytes.Equal(srcHash, dstHash), "dest BLAKE3 root must differ from live SHA-256 bank")
	s.assertCopiedKVProof("b3-bank", ics23.HashOp_BLAKE3)
	s.assertCopiedKVProof(ibcexported.StoreKey, ics23.HashOp_SHA256)
}

// TestLiveWriteAfterCopyLandsOnDest is the cutover invariant: live keepers
// still write through EndBlock of the v6.3 apply height (and the gap block).
// Dest must be recopied after mm.EndBlock while v6.4 is armed, or v6.4
// Deletes a stale SHA-256 tree.
func (s *UpgradeTestSuite) TestLiveWriteAfterCopyLandsOnDest() {
	s.SetupTest()
	if s.App.GetKey(terpiavl.BankB3) == nil {
		s.T().Skip("this ELF does not mount dest trees")
	}
	s.FundAcc(s.TestAccs[0], sdk.NewCoins(sdk.NewCoin(sdk.DefaultBondDenom, math.NewInt(1_000_000))))
	s.scheduleUpgrade()
	_, err := s.preModule.PreBlock(s.Ctx)
	s.Require().NoError(err)

	liveKey := []byte("v63-post-copy-live")
	liveVal := []byte("after-preblock")
	s.Ctx.KVStore(s.App.GetKey("bank")).Set(liveKey, liveVal)
	s.Require().Nil(s.Ctx.KVStore(s.App.GetKey(terpiavl.BankB3)).Get(liveKey),
		"dest must not already have the post-PreBlock live write")

	_, err = s.App.EndBlocker(s.Ctx)
	s.Require().NoError(err)
	s.Require().Equal(liveVal, s.Ctx.KVStore(s.App.GetKey(terpiavl.BankB3)).Get(liveKey),
		"dest must include live writes after v6.3 EndBlock recopy")

	// dest-only key is dropped
	orphan := []byte("v63-dest-only")
	s.Ctx.KVStore(s.App.GetKey(terpiavl.BankB3)).Set(orphan, []byte("stale"))
	s.Ctx.KVStore(s.App.GetKey("bank")).Delete(liveKey)
	gap := v63UpgradeHeight + 1
	s.Ctx = s.Ctx.WithHeaderInfo(header.Info{Height: gap, Time: s.Ctx.BlockTime().Add(time.Second)}).
		WithBlockHeight(gap)
	gapVal := []byte("gap-block")
	s.Ctx.KVStore(s.App.GetKey("bank")).Set(liveKey, gapVal)
	_, err = s.App.EndBlocker(s.Ctx)
	s.Require().NoError(err)
	s.Require().Equal(gapVal, s.Ctx.KVStore(s.App.GetKey(terpiavl.BankB3)).Get(liveKey),
		"dest must recopy on the gap block while v6.4 is armed")
	s.Require().Nil(s.Ctx.KVStore(s.App.GetKey(terpiavl.BankB3)).Get(orphan),
		"dest-only keys must be deleted so cutover matches last live commit")
}

func (s *UpgradeTestSuite) TestIBCNotCopied() {
	s.SetupTest()
	s.scheduleUpgrade()
	_, err := s.preModule.PreBlock(s.Ctx)
	s.Require().NoError(err)
	s.Require().Nil(s.App.GetKey("b3-ibc"))
	s.Require().Nil(s.App.GetKey("b3-08-wasm"))
	s.Require().NotNil(s.App.GetKey(ibcexported.StoreKey))
}

func (s *UpgradeTestSuite) scheduleUpgrade() {
	s.Ctx = s.Ctx.WithBlockHeight(v63UpgradeHeight - 1)
	plan := upgradetypes.Plan{Name: v63.UpgradeName, Height: v63UpgradeHeight}
	s.Require().NoError(s.App.UpgradeKeeper.ScheduleUpgrade(s.Ctx, plan))
	s.Ctx = s.Ctx.WithHeaderInfo(header.Info{Height: v63UpgradeHeight, Time: s.Ctx.BlockTime().Add(time.Second)}).
		WithBlockHeight(v63UpgradeHeight)
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
	hop, err := terpiavl.ProofHashOp(proof)
	s.Require().NoError(err)
	s.Require().Equal(want, hop, storeName)
	s.Require().NoError(terpiavl.VerifyExclusive(storeName, tree.Hash(), proof, firstK, firstV))
}

func TestV63LayoutConstants(t *testing.T) {
	if keepers.KeepersOnDest {
		t.Skip("v6.4 ELF")
	}
	var k keepers.AppKeepers
	k.GenerateKeys()
	if !keepers.MountDestStores {
		t.Skip("v63pre ELF")
	}
	if k.GetKey(terpiavl.BankB3) == nil {
		t.Fatal("v6.3 ELF must mount b3-bank")
	}
}

func TestNextUpgradeInfoCarriesV64Checksums(t *testing.T) {
	info := v63.NextUpgradeInfo
	if strings.HasPrefix(info, "http") {
		t.Skip("NextUpgradeInfo not stamped from v6.4/cosmovisor.json yet")
	}
	var wrap struct {
		Binaries map[string]string `json:"binaries"`
	}
	if err := json.Unmarshal([]byte(info), &wrap); err != nil {
		t.Fatalf("NextUpgradeInfo must be compact Cosmovisor JSON: %v", err)
	}
	for _, plat := range []string{"linux/amd64", "linux/arm64"} {
		u, ok := wrap.Binaries[plat]
		if !ok {
			t.Fatalf("missing %s in NextUpgradeInfo", plat)
		}
		if !strings.Contains(u, "checksum=sha256:") {
			t.Fatalf("%s missing checksum: %s", plat, u)
		}
		if !strings.Contains(u, "terpd-6.4.0-linux-") {
			t.Fatalf("%s must point at v6.4.0 tarball: %s", plat, u)
		}
	}
}
