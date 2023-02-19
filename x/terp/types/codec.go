package types

import (
	"github.com/cosmos/cosmos-sdk/codec"
	cdctypes "github.com/cosmos/cosmos-sdk/codec/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/msgservice"
)

func RegisterCodec(cdc *codec.LegacyAmino) {
	cdc.RegisterConcrete(&MsgCreateTerpid{}, "terp/CreateTerpid", nil)
	cdc.RegisterConcrete(&MsgUpdateTerpid{}, "terp/UpdateTerpid", nil)
	cdc.RegisterConcrete(&MsgDeleteTerpid{}, "terp/DeleteTerpid", nil)
	cdc.RegisterConcrete(&MsgCreateSupplychain{}, "terp/CreateSupplychain", nil)
	cdc.RegisterConcrete(&MsgUpdateSupplychain{}, "terp/UpdateSupplychain", nil)
	cdc.RegisterConcrete(&MsgDeleteSupplychain{}, "terp/DeleteSupplychain", nil)
	// this line is used by starport scaffolding # 2
}

func RegisterInterfaces(registry cdctypes.InterfaceRegistry) {
	registry.RegisterImplementations((*sdk.Msg)(nil),
		&MsgCreateTerpid{},
		&MsgUpdateTerpid{},
		&MsgDeleteTerpid{},
	)
	registry.RegisterImplementations((*sdk.Msg)(nil),
		&MsgCreateSupplychain{},
		&MsgUpdateSupplychain{},
		&MsgDeleteSupplychain{},
	)
	// this line is used by starport scaffolding # 3

	msgservice.RegisterMsgServiceDesc(registry, &_Msg_serviceDesc)
}

var (
	Amino     = codec.NewLegacyAmino()
	ModuleCdc = codec.NewProtoCodec(cdctypes.NewInterfaceRegistry())
)
