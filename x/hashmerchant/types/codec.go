package types

import (
	"github.com/cosmos/cosmos-sdk/codec"
	codectypes "github.com/cosmos/cosmos-sdk/codec/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/msgservice"
)

var (
	ModuleCdc = codec.NewProtoCodec(codectypes.NewInterfaceRegistry())
	AminoCdc  = codec.NewLegacyAmino()
)

const (
	registerChainAmino    = "terp/hashmerchant/register-chain"
	registerContractAmino = "terp/hashmerchant/register-contract"
	refillEscrowAmino     = "terp/hashmerchant/refill-escrow"
	updateParamsAmino     = "terp/hashmerchant/update-params"
)

func init() {
	RegisterLegacyAminoCodec(AminoCdc)
	sdk.RegisterLegacyAminoCodec(AminoCdc)
	AminoCdc.Seal()
}

// RegisterInterfaces registers the module's message types with the interface
// registry so the SDK can route them.
func RegisterInterfaces(registry codectypes.InterfaceRegistry) {
	registry.RegisterImplementations(
		(*sdk.Msg)(nil),
		&MsgRegisterChain{},
		&MsgRegisterContract{},
		&MsgRefillEscrow{},
		&MsgUpdateParams{},
	)
	msgservice.RegisterMsgServiceDesc(registry, &_Msg_serviceDesc)
}

// RegisterLegacyAminoCodec registers amino types for legacy signing.
func RegisterLegacyAminoCodec(cdc *codec.LegacyAmino) {
	cdc.RegisterConcrete(&MsgRegisterChain{}, registerChainAmino, nil)
	cdc.RegisterConcrete(&MsgRegisterContract{}, registerContractAmino, nil)
	cdc.RegisterConcrete(&MsgRefillEscrow{}, refillEscrowAmino, nil)
	cdc.RegisterConcrete(&MsgUpdateParams{}, updateParamsAmino, nil)
}
