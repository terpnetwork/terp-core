package types

import (
	sdk "github.com/cosmos/cosmos-sdk/types"
)

// --- MsgRegisterChain ---

func (m *MsgRegisterChain) ValidateBasic() error {
	if _, err := sdk.AccAddressFromBech32(m.Authority); err != nil {
		return ErrUnauthorized.Wrapf("invalid authority: %s", err)
	}
	if m.Chain.ChainUid == "" {
		return ErrInvalidChainUID.Wrap("chain_uid must not be empty")
	}
	return nil
}

func (m *MsgRegisterChain) GetSigners() []sdk.AccAddress {
	addr, _ := sdk.AccAddressFromBech32(m.Authority)
	return []sdk.AccAddress{addr}
}

// --- MsgRegisterContract ---

func (m *MsgRegisterContract) ValidateBasic() error {
	if _, err := sdk.AccAddressFromBech32(m.Sender); err != nil {
		return ErrUnauthorized.Wrapf("invalid sender: %s", err)
	}
	if m.ContractAddr == "" {
		return ErrContractNotFound.Wrap("contract_addr must not be empty")
	}
	if m.ChainUid == "" {
		return ErrInvalidChainUID.Wrap("chain_uid must not be empty")
	}
	if !m.Escrow.IsPositive() {
		return ErrInsufficientEscrow.Wrap("escrow must be positive")
	}
	return nil
}

func (m *MsgRegisterContract) GetSigners() []sdk.AccAddress {
	addr, _ := sdk.AccAddressFromBech32(m.Sender)
	return []sdk.AccAddress{addr}
}

// --- MsgRefillEscrow ---

func (m *MsgRefillEscrow) ValidateBasic() error {
	if _, err := sdk.AccAddressFromBech32(m.Sender); err != nil {
		return ErrUnauthorized.Wrapf("invalid sender: %s", err)
	}
	if m.ContractAddr == "" {
		return ErrContractNotFound.Wrap("contract_addr must not be empty")
	}
	if !m.Amount.IsPositive() {
		return ErrInsufficientEscrow.Wrap("amount must be positive")
	}
	return nil
}

func (m *MsgRefillEscrow) GetSigners() []sdk.AccAddress {
	addr, _ := sdk.AccAddressFromBech32(m.Sender)
	return []sdk.AccAddress{addr}
}

// --- MsgUpdateParams ---

func (m *MsgUpdateParams) ValidateBasic() error {
	if _, err := sdk.AccAddressFromBech32(m.Authority); err != nil {
		return ErrUnauthorized.Wrapf("invalid authority: %s", err)
	}
	return m.Params.Validate()
}

func (m *MsgUpdateParams) GetSigners() []sdk.AccAddress {
	addr, _ := sdk.AccAddressFromBech32(m.Authority)
	return []sdk.AccAddress{addr}
}
