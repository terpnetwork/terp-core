package types

import (
	sdk "github.com/cosmos/cosmos-sdk/types"
	sdkerrors "github.com/cosmos/cosmos-sdk/types/errors"
)

const (
	TypeMsgCreateTerpid = "create_terpid"
	TypeMsgUpdateTerpid = "update_terpid"
	TypeMsgDeleteTerpid = "delete_terpid"
)

var _ sdk.Msg = &MsgCreateTerpid{}

func NewMsgCreateTerpid(creator string, terpid string, address string) *MsgCreateTerpid {
	return &MsgCreateTerpid{
		Creator: creator,
		Terpid:  terpid,
		Address: address,
	}
}

func (msg *MsgCreateTerpid) Route() string {
	return RouterKey
}

func (msg *MsgCreateTerpid) Type() string {
	return TypeMsgCreateTerpid
}

func (msg *MsgCreateTerpid) GetSigners() []sdk.AccAddress {
	creator, err := sdk.AccAddressFromBech32(msg.Creator)
	if err != nil {
		panic(err)
	}
	return []sdk.AccAddress{creator}
}

func (msg *MsgCreateTerpid) GetSignBytes() []byte {
	bz := ModuleCdc.MustMarshalJSON(msg)
	return sdk.MustSortJSON(bz)
}

func (msg *MsgCreateTerpid) ValidateBasic() error {
	_, err := sdk.AccAddressFromBech32(msg.Creator)
	if err != nil {
		return sdkerrors.Wrapf(sdkerrors.ErrInvalidAddress, "invalid creator address (%s)", err)
	}
	return nil
}

var _ sdk.Msg = &MsgUpdateTerpid{}

func NewMsgUpdateTerpid(creator string, id uint64, terpid string, address string) *MsgUpdateTerpid {
	return &MsgUpdateTerpid{
		Id:      id,
		Creator: creator,
		Terpid:  terpid,
		Address: address,
	}
}

func (msg *MsgUpdateTerpid) Route() string {
	return RouterKey
}

func (msg *MsgUpdateTerpid) Type() string {
	return TypeMsgUpdateTerpid
}

func (msg *MsgUpdateTerpid) GetSigners() []sdk.AccAddress {
	creator, err := sdk.AccAddressFromBech32(msg.Creator)
	if err != nil {
		panic(err)
	}
	return []sdk.AccAddress{creator}
}

func (msg *MsgUpdateTerpid) GetSignBytes() []byte {
	bz := ModuleCdc.MustMarshalJSON(msg)
	return sdk.MustSortJSON(bz)
}

func (msg *MsgUpdateTerpid) ValidateBasic() error {
	_, err := sdk.AccAddressFromBech32(msg.Creator)
	if err != nil {
		return sdkerrors.Wrapf(sdkerrors.ErrInvalidAddress, "invalid creator address (%s)", err)
	}
	return nil
}

var _ sdk.Msg = &MsgDeleteTerpid{}

func NewMsgDeleteTerpid(creator string, id uint64) *MsgDeleteTerpid {
	return &MsgDeleteTerpid{
		Id:      id,
		Creator: creator,
	}
}

func (msg *MsgDeleteTerpid) Route() string {
	return RouterKey
}

func (msg *MsgDeleteTerpid) Type() string {
	return TypeMsgDeleteTerpid
}

func (msg *MsgDeleteTerpid) GetSigners() []sdk.AccAddress {
	creator, err := sdk.AccAddressFromBech32(msg.Creator)
	if err != nil {
		panic(err)
	}
	return []sdk.AccAddress{creator}
}

func (msg *MsgDeleteTerpid) GetSignBytes() []byte {
	bz := ModuleCdc.MustMarshalJSON(msg)
	return sdk.MustSortJSON(bz)
}

func (msg *MsgDeleteTerpid) ValidateBasic() error {
	_, err := sdk.AccAddressFromBech32(msg.Creator)
	if err != nil {
		return sdkerrors.Wrapf(sdkerrors.ErrInvalidAddress, "invalid creator address (%s)", err)
	}
	return nil
}
