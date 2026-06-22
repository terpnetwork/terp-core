package testutils

import (
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"time"

	abci "github.com/cometbft/cometbft/abci/types"

	coreheader "cosmossdk.io/core/header"

	"cosmossdk.io/math"
	"github.com/cometbft/cometbft/crypto/ed25519"
	cmtproto "github.com/cometbft/cometbft/proto/tendermint/types"
	"github.com/cosmos/cosmos-sdk/baseapp"
	sdk "github.com/cosmos/cosmos-sdk/types"
	bankkeeper "github.com/cosmos/cosmos-sdk/x/bank/keeper"
	minttypes "github.com/cosmos/cosmos-sdk/x/mint/types"
	stakinghelper "github.com/cosmos/cosmos-sdk/x/staking/testutil"
	stakingtypes "github.com/cosmos/cosmos-sdk/x/staking/types"
	"github.com/terpnetwork/terp-core/v5/app"

	"github.com/cometbft/cometbft/crypto"
	tmproto "github.com/cometbft/cometbft/proto/tendermint/types"
	tmtypes "github.com/cometbft/cometbft/types"
	"github.com/stretchr/testify/suite"

	"crypto/sha256"

	cryptocodec "github.com/cosmos/cosmos-sdk/crypto/codec"
	cosmosed25519 "github.com/cosmos/cosmos-sdk/crypto/keys/ed25519"
	cryptotypes "github.com/cosmos/cosmos-sdk/crypto/types"
	"github.com/cosmos/cosmos-sdk/x/bank/testutil"

	wasmtypes "github.com/CosmWasm/wasmd/x/wasm/types"

	"github.com/cosmos/cosmos-sdk/testutil/testdata"
)

var (
	SecondaryDenom       = "uthiol"
	SecondaryAmount      = math.NewInt(100000000)
	baseTestAccts        = []sdk.AccAddress{}
	defaultTestStartTime = time.Now().UTC()
	testDescription      = stakingtypes.NewDescription("test_moniker", "test_identity", "test_website", "test_security_contact", "test_details")
)

type KeeperTestHelper struct {
	suite.Suite

	App         *app.TerpApp                    // Mock terp application
	Ctx         sdk.Context                     // simulated context
	QueryHelper *baseapp.QueryServiceTestHelper // GRPC query simulator
	TestAccs    []sdk.AccAddress                // Test accounts

	StakingHelper *stakinghelper.Helper // Useful staking helpers

	// set to true if any method alters baseapp/abci is used.
	// controls whether or not to reuse app instance or set new one.
	hasUsedAbci bool
	withCaching bool
}

func init() {
	baseTestAccts = CreateRandomAccounts(3)
}

func (s *KeeperTestHelper) Reset() {
	if s.hasUsedAbci || !s.withCaching {
		s.withCaching = true
		s.Setup()
	} else {
		s.setupGeneral()
	}
}

func (s *KeeperTestHelper) Setup() {
	dir, err := os.MkdirTemp("", fmt.Sprintf("terp-test-%d-*", rand.Int()))

	if err != nil {
		panic(fmt.Sprintf("failed creating temporary directory: %v", err))
	}

	// Create minimal config files for testing
	err = s.createTestConfigFiles(dir)
	if err != nil {
		panic(fmt.Sprintf("failed creating test config files: %v", err))
	}

	s.T().Cleanup(func() { os.RemoveAll(dir); s.withCaching = false })
	s.App = SetupWithCustomHome(false, dir)
	// configure ctx, caching, query helper,& test accounts
	s.setupGeneral()

}

func (s *KeeperTestHelper) setupGeneral() {
	s.setupGeneralCustomChainId("terp-2b")
}

func (s *KeeperTestHelper) setupGeneralCustomChainId(chainId string) {
	s.Ctx = s.App.BaseApp.NewContextLegacy(false,
		cmtproto.Header{Height: 1, ChainID: chainId, Time: defaultTestStartTime})
	if s.withCaching {
		s.Ctx, _ = s.Ctx.CacheContext()
	}
	s.QueryHelper = &baseapp.QueryServiceTestHelper{
		GRPCQueryRouter: s.App.GRPCQueryRouter(),
		Ctx:             s.Ctx,
	}

	s.TestAccs = []sdk.AccAddress{}
	s.TestAccs = append(s.TestAccs, baseTestAccts...)
	s.hasUsedAbci = false
}

// createTestConfigFiles creates minimal config files needed for upgrade handler tests
func (s *KeeperTestHelper) createTestConfigFiles(homeDir string) error {
	configDir := filepath.Join(homeDir, "config")
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		return err
	}
	configContent := `
# Minimal config.toml for testing
[consensus]
timeout_commit = "5s"
timeout_propose = "3s"
timeout_propose_delta = "500ms"
timeout_prevote = "1s"
timeout_prevote_delta = "500ms"
timeout_precommit = "1s"
timeout_precommit_delta = "500ms"
 
`

	configPath := filepath.Join(configDir, "config.toml")
	return os.WriteFile(configPath, []byte(configContent), 0o644)
}

// CreateRandomAccounts is a function return a list of randomly generated AccAddresses
func CreateRandomAccounts(numAccts int) []sdk.AccAddress {
	testAddrs := make([]sdk.AccAddress, numAccts)
	for i := 0; i < numAccts; i++ {
		pk := ed25519.GenPrivKey().PubKey()
		testAddrs[i] = sdk.AccAddress(pk.Address())
	}

	return testAddrs
}

type GenerateAccountStrategy func(int) []sdk.AccAddress
type BondDenomProvider interface {
	BondDenom(ctx sdk.Context) string
}

// AddTestAddrs constructs and returns accNum amount of accounts with an
// initial balance of accAmt in random order
func AddTestAddrs(bankKeeper bankkeeper.Keeper, stakingKeeper BondDenomProvider, ctx sdk.Context, accNum int, accAmt math.Int) []sdk.AccAddress {
	return addTestAddrs(bankKeeper, stakingKeeper, ctx, accNum, accAmt, CreateRandomAccounts)
}

// addTestAddrs adds an account to the tests.
func addTestAddrs(bankKeeper bankkeeper.Keeper, stakingKeeper BondDenomProvider, ctx sdk.Context, accNum int, accAmt math.Int, strategy GenerateAccountStrategy) []sdk.AccAddress {
	testAddrs := strategy(accNum)
	initCoins := sdk.NewCoins(sdk.NewCoin(stakingKeeper.BondDenom(ctx), accAmt))

	for _, addr := range testAddrs {
		initAccountWithCoins(bankKeeper, ctx, addr, initCoins)
	}

	return testAddrs
}

func initAccountWithCoins(bankKeeper bankkeeper.Keeper, ctx sdk.Context, addr sdk.AccAddress, coins sdk.Coins) {
	if err := bankKeeper.MintCoins(ctx, minttypes.ModuleName, coins); err != nil {
		panic(err)
	}

	if err := bankKeeper.SendCoinsFromModuleToAccount(ctx, minttypes.ModuleName, addr, coins); err != nil {
		panic(err)
	}
}

// ConvertAddrsToValAddrs converts the provided addresses to ValAddress.
func ConvertAddrsToValAddrs(addrs []sdk.AccAddress) []sdk.ValAddress {
	valAddrs := make([]sdk.ValAddress, len(addrs))

	for i, addr := range addrs {
		valAddrs[i] = sdk.ValAddress(addr)
	}

	return valAddrs
}

var _ tmtypes.PrivValidator = PV{}

// PV implements PrivValidator without any safety or persistence.
// Only use it for testing.
type PV struct {
	PrivKey cryptotypes.PrivKey
}

func NewPV() PV {
	return PV{cosmosed25519.GenPrivKey()}
}

// GetPubKey implements PrivValidator interface
func (pv PV) GetPubKey() (crypto.PubKey, error) {
	return cryptocodec.ToCmtPubKeyInterface(pv.PrivKey.PubKey())
}

// SignVote implements PrivValidator interface
func (pv PV) SignVote(chainID string, vote *tmproto.Vote) error {
	signBytes := tmtypes.VoteSignBytes(chainID, vote)
	sig, err := pv.PrivKey.Sign(signBytes)
	if err != nil {
		return err
	}
	vote.Signature = sig
	return nil
}

// SignProposal implements PrivValidator interface
func (pv PV) SignProposal(chainID string, proposal *tmproto.Proposal) error {
	signBytes := tmtypes.ProposalSignBytes(chainID, proposal)
	sig, err := pv.PrivKey.Sign(signBytes)
	if err != nil {
		return err
	}
	proposal.Signature = sig
	return nil
}

// FundAcc funds target address with specified amount.
func (s *KeeperTestHelper) FundAcc(acc sdk.AccAddress, amounts sdk.Coins) {
	err := testutil.FundAccount(s.Ctx, s.App.AppKeepers.BankKeeper, acc, amounts)
	s.Require().NoError(err)
}

// FundModuleAcc funds target modules with specified amount.
func (s *KeeperTestHelper) FundModuleAcc(moduleName string, amounts sdk.Coins) {
	err := testutil.FundModuleAccount(s.Ctx, s.App.AppKeepers.BankKeeper, moduleName, amounts)
	s.Require().NoError(err)
}

func (s *KeeperTestHelper) MintCoins(coins sdk.Coins) {
	err := s.App.AppKeepers.BankKeeper.MintCoins(s.Ctx, minttypes.ModuleName, coins)
	s.Require().NoError(err)
}

// AssertEventEmitted asserts that ctx's event manager has emitted the given number of events
// of the given type.
func (s *KeeperTestHelper) AssertEventEmitted(ctx sdk.Context, eventTypeExpected string, numEventsExpected int) {
	allEvents := ctx.EventManager().Events()
	// filter out other events
	actualEvents := make([]sdk.Event, 0)
	for _, event := range allEvents {
		if event.Type == eventTypeExpected {
			actualEvents = append(actualEvents, event)
		}
	}
	s.Equal(numEventsExpected, len(actualEvents))
}

func (s *KeeperTestHelper) StoreCode(wasmContract []byte) {
	_, _, sender := testdata.KeyTestPubAddr()
	msg := wasmtypes.MsgStoreCodeFixture(func(m *wasmtypes.MsgStoreCode) {
		m.WASMByteCode = wasmContract
		m.Sender = sender.String()
	})
	rsp, err := s.App.MsgServiceRouter().Handler(msg)(s.Ctx, msg)
	s.Require().NoError(err)
	var result wasmtypes.MsgStoreCodeResponse
	s.Require().NoError(s.App.AppCodec().Unmarshal(rsp.Data, &result))
	s.Require().Equal(result.CodeID, 0)
	expHash := sha256.Sum256(wasmContract)
	s.Require().Equal(expHash[:], result.Checksum)
	// and
	info := s.App.AppKeepers.WasmKeeper.GetCodeInfo(s.Ctx, result.CodeID)
	s.Require().NotNil(info)
	s.Require().Equal(expHash[:], info.CodeHash)
	s.Require().Equal(sender.String(), info.Creator)
	s.Require().Equal(wasmtypes.DefaultParams().InstantiateDefaultPermission.With(sender), info.InstantiateConfig)
}

func (s *KeeperTestHelper) InstantiateContract(sender string, admin string, wasmContract []byte) string {
	msgStoreCode := wasmtypes.MsgStoreCodeFixture(func(m *wasmtypes.MsgStoreCode) {
		m.WASMByteCode = wasmContract
		m.Sender = sender
	})
	var scResp wasmtypes.MsgStoreCodeResponse
	storeResp, err := s.App.MsgServiceRouter().Handler(msgStoreCode)(s.Ctx, msgStoreCode)
	s.Require().NoError(err)
	s.Require().NoError(s.App.AppCodec().Unmarshal(storeResp.Data, &scResp))

	msgInstantiate := wasmtypes.MsgInstantiateContractFixture(func(m *wasmtypes.MsgInstantiateContract) {
		m.Sender = sender
		m.Admin = admin
		m.Msg = []byte(`{}`)
		m.CodeID = scResp.CodeID
	})
	resp, err := s.App.MsgServiceRouter().Handler(msgInstantiate)(s.Ctx, msgInstantiate)
	s.Require().NoError(err)
	var result wasmtypes.MsgInstantiateContractResponse
	s.Require().NoError(s.App.AppCodec().Unmarshal(resp.Data, &result))
	contractInfo := s.App.AppKeepers.WasmKeeper.GetContractInfo(s.Ctx, sdk.MustAccAddressFromBech32(result.Address))
	s.Require().Equal(contractInfo.CodeID, scResp.CodeID)
	s.Require().Equal(contractInfo.Admin, admin)
	s.Require().Equal(contractInfo.Creator, sender)

	return result.Address
}

func (s *KeeperTestHelper) Commit() {
	_, err := s.App.FinalizeBlock(&abci.RequestFinalizeBlock{Height: s.Ctx.BlockHeight(), Time: s.Ctx.BlockTime()})
	if err != nil {
		panic(err)
	}
	_, err = s.App.Commit()
	if err != nil {
		panic(err)
	}

	newBlockTime := s.Ctx.BlockTime().Add(time.Second)

	header := s.Ctx.BlockHeader()
	header.Time = newBlockTime
	header.Height++

	s.Ctx = s.App.BaseApp.NewUncachedContext(false, header).WithHeaderInfo(coreheader.Info{
		Height: header.Height,
		Time:   header.Time,
	})

	s.hasUsedAbci = true
}

// // BeginNewBlock starts a new block.
// func (s *KeeperTestHelper) BeginNewBlock() {
// 	var valAddr []byte

// 	validators, err := s.App.AppKeepers.StakingKeeper.GetAllValidators(s.Ctx)
// 	s.Require().NoError(err)
// 	if len(validators) >= 1 {
// 		valAddrFancy, err := validators[0].GetConsAddr()
// 		s.Require().NoError(err)
// 		valAddr = valAddrFancy
// 	} else {
// 		valAddrFancy := s.SetupValidator(stakingtypes.Bonded)
// 		validator, _ := s.App.AppKeepers.StakingKeeper.GetValidator(s.Ctx, valAddrFancy)
// 		valAddr2, _ := validator.GetConsAddr()
// 		valAddr = valAddr2
// 	}

// 	s.BeginNewBlockWithProposer(valAddr)
// }

// // BeginNewBlockWithProposer begins a new block with a proposer.
// func (s *KeeperTestHelper) BeginNewBlockWithProposer(proposer sdk.ValAddress) {
// 	validator, err := s.App.AppKeepers.StakingKeeper.GetValidator(s.Ctx, proposer)
// 	s.Assert().NoError(err)

// 	valConsAddr, err := validator.GetConsAddr()
// 	s.Require().NoError(err)

// 	valAddr := valConsAddr
// 	newBlockTime := s.Ctx.BlockTime().Add(3 * time.Second)

// 	header := tmtypes.Header{Height: s.Ctx.BlockHeight() + 1, Time: newBlockTime}
// 	s.Ctx = s.Ctx.WithBlockTime(newBlockTime).WithBlockHeight(s.Ctx.BlockHeight() + 1)
// 	voteInfos := []abci.VoteInfo{{
// 		Validator:   abci.Validator{Address: valAddr, Power: 1000},
// 		BlockIdFlag: tmtypes.BlockIDFlagCommit,
// 	}}
// 	s.Ctx = s.Ctx.WithVoteInfos(voteInfos)

// 	_, err = fmt.Println("beginning block ", s.Ctx.BlockHeight())
// 	s.Require().NoError(err)

// 	_, err = s.App.BeginBlocker(s.Ctx)
// 	s.Require().NoError(err)

// 	s.Ctx = s.App.NewContextLegacy(false, header)
// 	s.hasUsedAbci = true
// }

// EndBlock ends the block, and runs commit
func (s *KeeperTestHelper) EndBlock() {
	_, err := s.App.EndBlocker(s.Ctx)
	s.Require().NoError(err)
	s.hasUsedAbci = true
}
