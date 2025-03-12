package keeper_test

import (
	"crypto/sha256"

	_ "embed"

	"cosmossdk.io/math"
	wasmtypes "github.com/CosmWasm/wasmd/x/wasm/types"

	"github.com/cosmos/cosmos-sdk/testutil/testdata"
	sdk "github.com/cosmos/cosmos-sdk/types"

	"github.com/terpnetwork/terp-core/v4/x/feeshare/types"
)

//go:embed testdata/reflect.wasm
var wasmContract []byte

func (s *KeeperTestSuite) StoreCode() {
	_, _, sender := testdata.KeyTestPubAddr()
	msg := wasmtypes.MsgStoreCodeFixture(func(m *wasmtypes.MsgStoreCode) {
		m.WASMByteCode = wasmContract
		m.Sender = sender.String()
	})
	rsp, err := s.App.MsgServiceRouter().Handler(msg)(s.Ctx, msg)
	s.Require().NoError(err)
	var result wasmtypes.MsgStoreCodeResponse
	s.Require().NoError(s.App.AppCodec().Unmarshal(rsp.Data, &result))
	s.Require().Equal(uint64(1), result.CodeID)
	expHash := sha256.Sum256(wasmContract)
	s.Require().Equal(expHash[:], result.Checksum)
	// and
	info := s.App.WasmKeeper.GetCodeInfo(s.Ctx, 1)
	s.Require().NotNil(info)
	s.Require().Equal(expHash[:], info.CodeHash)
	s.Require().Equal(sender.String(), info.Creator)
	s.Require().Equal(wasmtypes.DefaultParams().InstantiateDefaultPermission.With(sender), info.InstantiateConfig)
}

func (s *KeeperTestSuite) InstantiateContract(sender string, admin string) string {

	msgStoreCode := wasmtypes.MsgStoreCodeFixture(func(m *wasmtypes.MsgStoreCode) {
		m.WASMByteCode = wasmContract
		m.Sender = sender
	})
	_, err := s.App.MsgServiceRouter().Handler(msgStoreCode)(s.Ctx, msgStoreCode)
	s.Require().NoError(err)

	msgInstantiate := wasmtypes.MsgInstantiateContractFixture(func(m *wasmtypes.MsgInstantiateContract) {
		m.Sender = sender
		m.Admin = admin
		m.Msg = []byte(`{}`)
	})

	resp, err := s.App.MsgServiceRouter().Handler(msgInstantiate)(s.Ctx, msgInstantiate)
	s.Require().NoError(err)
	var result wasmtypes.MsgInstantiateContractResponse
	s.Require().NoError(s.App.AppCodec().Unmarshal(resp.Data, &result))
	contractInfo := s.App.WasmKeeper.GetContractInfo(s.Ctx, sdk.MustAccAddressFromBech32(result.Address))
	s.Require().Equal(contractInfo.CodeID, uint64(1))
	s.Require().Equal(contractInfo.Admin, admin)
	s.Require().Equal(contractInfo.Creator, sender)

	return result.Address
}

func (s *KeeperTestSuite) TestGetContractAdminOrCreatorAddress() {
	_, _, sender := testdata.KeyTestPubAddr()
	_, _, admin := testdata.KeyTestPubAddr()
	_ = s.FundAccount(s.Ctx, sender, sdk.NewCoins(sdk.NewCoin("stake", math.NewInt(1_000_000))))
	_ = s.FundAccount(s.Ctx, admin, sdk.NewCoins(sdk.NewCoin("stake", math.NewInt(1_000_000))))

	noAdminContractAddress := s.InstantiateContract(sender.String(), "")
	withAdminContractAddress := s.InstantiateContract(sender.String(), admin.String())

	for _, tc := range []struct {
		desc            string
		contractAddress string
		deployerAddress string
		shouldErr       bool
	}{
		{
			desc:            "Success - Creator",
			contractAddress: noAdminContractAddress,
			deployerAddress: sender.String(),
			shouldErr:       false,
		},
		{
			desc:            "Success - Admin",
			contractAddress: withAdminContractAddress,
			deployerAddress: admin.String(),
			shouldErr:       false,
		},
		{
			desc:            "Error - Invalid deployer",
			contractAddress: noAdminContractAddress,
			deployerAddress: "Invalid",
			shouldErr:       true,
		},
	} {
		tc := tc
		s.Run(tc.desc, func() {
			if !tc.shouldErr {
				_, err := s.App.FeeShareKeeper.GetContractAdminOrCreatorAddress(s.Ctx, sdk.MustAccAddressFromBech32(tc.contractAddress), tc.deployerAddress)
				s.Require().NoError(err)
			} else {
				_, err := s.App.FeeShareKeeper.GetContractAdminOrCreatorAddress(s.Ctx, sdk.MustAccAddressFromBech32(tc.contractAddress), tc.deployerAddress)
				s.Require().Error(err)
			}
		})
	}
}

func (s *KeeperTestSuite) TestRegisterFeeShare() {
	_, _, sender := testdata.KeyTestPubAddr()
	_ = s.FundAccount(s.Ctx, sender, sdk.NewCoins(sdk.NewCoin("stake", math.NewInt(1_000_000))))

	contractAddress := s.InstantiateContract(sender.String(), "")
	contractAddress2 := s.InstantiateContract(contractAddress, contractAddress)

	_, _, withdrawer := testdata.KeyTestPubAddr()

	for _, tc := range []struct {
		desc      string
		msg       *types.MsgRegisterFeeShare
		resp      *types.MsgRegisterFeeShareResponse
		shouldErr bool
	}{
		{
			desc: "Invalid contract address",
			msg: &types.MsgRegisterFeeShare{
				ContractAddress:   "Invalid",
				DeployerAddress:   sender.String(),
				WithdrawerAddress: withdrawer.String(),
			},
			resp:      &types.MsgRegisterFeeShareResponse{},
			shouldErr: true,
		},
		{
			desc: "Invalid deployer address",
			msg: &types.MsgRegisterFeeShare{
				ContractAddress:   contractAddress,
				DeployerAddress:   "Invalid",
				WithdrawerAddress: withdrawer.String(),
			},
			resp:      &types.MsgRegisterFeeShareResponse{},
			shouldErr: true,
		},
		{
			desc: "Invalid withdrawer address",
			msg: &types.MsgRegisterFeeShare{
				ContractAddress:   contractAddress,
				DeployerAddress:   sender.String(),
				WithdrawerAddress: "Invalid",
			},
			resp:      &types.MsgRegisterFeeShareResponse{},
			shouldErr: true,
		},
		{
			desc: "Success",
			msg: &types.MsgRegisterFeeShare{
				ContractAddress:   contractAddress,
				DeployerAddress:   sender.String(),
				WithdrawerAddress: withdrawer.String(),
			},
			resp:      &types.MsgRegisterFeeShareResponse{},
			shouldErr: false,
		},
		{
			desc: "Invalid withdraw address for factory contract",
			msg: &types.MsgRegisterFeeShare{
				ContractAddress:   contractAddress2,
				DeployerAddress:   sender.String(),
				WithdrawerAddress: sender.String(),
			},
			resp:      &types.MsgRegisterFeeShareResponse{},
			shouldErr: true,
		},
		{
			desc: "Success register factory contract to itself",
			msg: &types.MsgRegisterFeeShare{
				ContractAddress:   contractAddress2,
				DeployerAddress:   sender.String(),
				WithdrawerAddress: contractAddress2,
			},
			resp:      &types.MsgRegisterFeeShareResponse{},
			shouldErr: false,
		},
	} {
		tc := tc
		s.Run(tc.desc, func() {
			goCtx := sdk.WrapSDKContext(s.Ctx)
			if !tc.shouldErr {
				resp, err := s.feeShareMsgServer.RegisterFeeShare(goCtx, tc.msg)
				s.Require().NoError(err)
				s.Require().Equal(resp, tc.resp)
			} else {
				resp, err := s.feeShareMsgServer.RegisterFeeShare(goCtx, tc.msg)
				s.Require().Error(err)
				s.Require().Nil(resp)
			}
		})
	}
}

func (s *KeeperTestSuite) TestUpdateFeeShare() {
	_, _, sender := testdata.KeyTestPubAddr()
	_ = s.FundAccount(s.Ctx, sender, sdk.NewCoins(sdk.NewCoin("stake", math.NewInt(1_000_000))))

	contractAddress := s.InstantiateContract(sender.String(), "")
	_, _, withdrawer := testdata.KeyTestPubAddr()

	contractAddressNoRegisFeeShare := s.InstantiateContract(sender.String(), "")
	s.Require().NotEqual(contractAddress, contractAddressNoRegisFeeShare)

	// RegsisFeeShare
	goCtx := s.Ctx.WithEventManager(sdk.NewEventManager())
	msg := &types.MsgRegisterFeeShare{
		ContractAddress:   contractAddress,
		DeployerAddress:   sender.String(),
		WithdrawerAddress: withdrawer.String(),
	}
	_, err := s.feeShareMsgServer.RegisterFeeShare(goCtx, msg)
	s.Require().NoError(err)
	_, _, newWithdrawer := testdata.KeyTestPubAddr()
	s.Require().NotEqual(withdrawer, newWithdrawer)

	for _, tc := range []struct {
		desc      string
		msg       *types.MsgUpdateFeeShare
		resp      *types.MsgCancelFeeShareResponse
		shouldErr bool
	}{
		{
			desc: "Invalid - contract not regis",
			msg: &types.MsgUpdateFeeShare{
				ContractAddress:   contractAddressNoRegisFeeShare,
				DeployerAddress:   sender.String(),
				WithdrawerAddress: newWithdrawer.String(),
			},
			resp:      nil,
			shouldErr: true,
		},
		{
			desc: "Invalid - Invalid DeployerAddress",
			msg: &types.MsgUpdateFeeShare{
				ContractAddress:   contractAddress,
				DeployerAddress:   "Invalid",
				WithdrawerAddress: newWithdrawer.String(),
			},
			resp:      nil,
			shouldErr: true,
		},
		{
			desc: "Invalid - Invalid WithdrawerAddress",
			msg: &types.MsgUpdateFeeShare{
				ContractAddress:   contractAddress,
				DeployerAddress:   sender.String(),
				WithdrawerAddress: "Invalid",
			},
			resp:      nil,
			shouldErr: true,
		},
		{
			desc: "Invalid - Invalid WithdrawerAddress not change",
			msg: &types.MsgUpdateFeeShare{
				ContractAddress:   contractAddress,
				DeployerAddress:   sender.String(),
				WithdrawerAddress: withdrawer.String(),
			},
			resp:      nil,
			shouldErr: true,
		},
		{
			desc: "Success",
			msg: &types.MsgUpdateFeeShare{
				ContractAddress:   contractAddress,
				DeployerAddress:   sender.String(),
				WithdrawerAddress: newWithdrawer.String(),
			},
			resp:      &types.MsgCancelFeeShareResponse{},
			shouldErr: false,
		},
	} {
		tc := tc
		s.Run(tc.desc, func() {
			goCtx := s.Ctx
			if !tc.shouldErr {
				_, err := s.feeShareMsgServer.UpdateFeeShare(goCtx, tc.msg)
				s.Require().NoError(err)
			} else {
				resp, err := s.feeShareMsgServer.UpdateFeeShare(goCtx, tc.msg)
				s.Require().Error(err)
				s.Require().Nil(resp)
			}
		})
	}
}

func (s *KeeperTestSuite) TestCancelFeeShare() {

	_, _, sender := testdata.KeyTestPubAddr()
	_ = s.FundAccount(s.Ctx, sender, sdk.NewCoins(sdk.NewCoin("stake", math.NewInt(1_000_000))))

	contractAddress := s.InstantiateContract(sender.String(), "")
	_, _, withdrawer := testdata.KeyTestPubAddr()

	// RegsisFeeShare
	goCtx := s.Ctx.WithEventManager(sdk.NewEventManager())
	msg := &types.MsgRegisterFeeShare{
		ContractAddress:   contractAddress,
		DeployerAddress:   sender.String(),
		WithdrawerAddress: withdrawer.String(),
	}
	_, err := s.feeShareMsgServer.RegisterFeeShare(goCtx, msg)
	s.Require().NoError(err)

	for _, tc := range []struct {
		desc      string
		msg       *types.MsgCancelFeeShare
		resp      *types.MsgCancelFeeShareResponse
		shouldErr bool
	}{
		{
			desc: "Invalid - contract Address",
			msg: &types.MsgCancelFeeShare{
				ContractAddress: "Invalid",
				DeployerAddress: sender.String(),
			},
			resp:      nil,
			shouldErr: true,
		},
		{
			desc: "Invalid - deployer Address",
			msg: &types.MsgCancelFeeShare{
				ContractAddress: contractAddress,
				DeployerAddress: "Invalid",
			},
			resp:      nil,
			shouldErr: true,
		},
		{
			desc: "Success",
			msg: &types.MsgCancelFeeShare{
				ContractAddress: contractAddress,
				DeployerAddress: sender.String(),
			},
			resp:      &types.MsgCancelFeeShareResponse{},
			shouldErr: false,
		},
	} {
		tc := tc
		s.Run(tc.desc, func() {
			goCtx := s.Ctx.WithEventManager(sdk.NewEventManager())
			if !tc.shouldErr {
				resp, err := s.feeShareMsgServer.CancelFeeShare(goCtx, tc.msg)
				s.Require().NoError(err)
				s.Require().Equal(resp, tc.resp)
			} else {
				resp, err := s.feeShareMsgServer.CancelFeeShare(goCtx, tc.msg)
				s.Require().Error(err)
				s.Require().Equal(resp, tc.resp)
			}
		})
	}
}
