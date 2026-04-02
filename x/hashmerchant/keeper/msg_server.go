package keeper

import (
	"context"

	sdk "github.com/cosmos/cosmos-sdk/types"
	govtypes "github.com/cosmos/cosmos-sdk/x/gov/types"

	"github.com/terpnetwork/terp-core/v5/x/hashmerchant/types"
)

var _ types.MsgServer = msgServer{}

type msgServer struct {
	k Keeper
}

// NewMsgServerImpl returns an implementation of the MsgServer interface.
func NewMsgServerImpl(k Keeper) types.MsgServer {
	return &msgServer{k: k}
}

// RegisterChain adds a foreign chain to the registry. Governance-gated.
func (ms msgServer) RegisterChain(goCtx context.Context, msg *types.MsgRegisterChain) (*types.MsgRegisterChainResponse, error) {
	if ms.k.authority != msg.Authority {
		return nil, govtypes.ErrInvalidSigner.Wrapf(
			"unauthorised: expected %s, got %s", ms.k.authority, msg.Authority,
		)
	}
	if ms.k.HasRegisteredChain(goCtx, msg.Chain.ChainUid) {
		return nil, types.ErrChainAlreadyExists.Wrapf("chain_uid: %s", msg.Chain.ChainUid)
	}
	if err := ms.k.SetRegisteredChain(goCtx, msg.Chain); err != nil {
		return nil, err
	}

	ctx := sdk.UnwrapSDKContext(goCtx)
	ctx.EventManager().EmitEvent(sdk.NewEvent(
		"hashmerchant_register_chain",
		sdk.NewAttribute("chain_uid", msg.Chain.ChainUid),
		sdk.NewAttribute("name", msg.Chain.Name),
	))
	return &types.MsgRegisterChainResponse{}, nil
}

// RegisterContract registers a CosmWasm contract for sudo callbacks.
// The sender must pay at least min_escrow_amount.
func (ms msgServer) RegisterContract(goCtx context.Context, msg *types.MsgRegisterContract) (*types.MsgRegisterContractResponse, error) {
	// Verify the target chain exists and is enabled.
	chain, err := ms.k.GetRegisteredChain(goCtx, msg.ChainUid)
	if err != nil {
		return nil, err
	}
	if !chain.Enabled {
		return nil, types.ErrChainDisabled.Wrapf("chain_uid: %s", msg.ChainUid)
	}

	params, err := ms.k.GetParams(goCtx)
	if err != nil {
		return nil, err
	}

	// Validate escrow amount.
	if msg.Escrow.Denom != params.EscrowDenom {
		return nil, types.ErrInsufficientEscrow.Wrapf(
			"expected denom %s, got %s", params.EscrowDenom, msg.Escrow.Denom,
		)
	}
	if msg.Escrow.Amount.LT(params.MinEscrowAmount) {
		return nil, types.ErrInsufficientEscrow.Wrapf(
			"minimum %s, got %s", params.MinEscrowAmount, msg.Escrow.Amount,
		)
	}

	// Transfer escrow to module account.
	sender, _ := sdk.AccAddressFromBech32(msg.Sender)
	if err := ms.k.bankKeeper.SendCoinsFromAccountToModule(
		goCtx, sender, types.ModuleName, sdk.NewCoins(msg.Escrow),
	); err != nil {
		return nil, err
	}

	ctx := sdk.UnwrapSDKContext(goCtx)

	// Compute paid_until_height: escrow amount / min_escrow_amount * prune_interval.
	// Simple model: each min_escrow_amount buys prune_interval blocks.
	periods := msg.Escrow.Amount.Quo(params.MinEscrowAmount).Uint64()
	paidUntil := uint64(ctx.BlockHeight()) + periods*params.PruneInterval

	// Store contract registration.
	contract := types.RegisteredContract{
		ContractAddr: msg.ContractAddr,
		ChainUid:     msg.ChainUid,
		SubstoreKeys: msg.SubstoreKeys,
		Enabled:      true,
	}
	if err := ms.k.SetRegisteredContract(goCtx, contract); err != nil {
		return nil, err
	}

	// Store escrow record.
	record := types.EscrowRecord{
		ContractAddr:    msg.ContractAddr,
		Amount:          msg.Escrow,
		PaidUntilHeight: paidUntil,
	}
	if err := ms.k.SetEscrowRecord(goCtx, record); err != nil {
		return nil, err
	}

	ctx.EventManager().EmitEvent(sdk.NewEvent(
		"hashmerchant_register_contract",
		sdk.NewAttribute("contract_addr", msg.ContractAddr),
		sdk.NewAttribute("chain_uid", msg.ChainUid),
		sdk.NewAttribute("sender", msg.Sender),
	))
	return &types.MsgRegisterContractResponse{}, nil
}

// RefillEscrow tops up the escrow for an existing contract.
func (ms msgServer) RefillEscrow(goCtx context.Context, msg *types.MsgRefillEscrow) (*types.MsgRefillEscrowResponse, error) {
	record, err := ms.k.GetEscrowRecord(goCtx, msg.ContractAddr)
	if err != nil {
		return nil, err
	}

	params, err := ms.k.GetParams(goCtx)
	if err != nil {
		return nil, err
	}

	if msg.Amount.Denom != params.EscrowDenom {
		return nil, types.ErrInsufficientEscrow.Wrapf(
			"expected denom %s, got %s", params.EscrowDenom, msg.Amount.Denom,
		)
	}

	// Transfer to module account.
	sender, _ := sdk.AccAddressFromBech32(msg.Sender)
	if err := ms.k.bankKeeper.SendCoinsFromAccountToModule(
		goCtx, sender, types.ModuleName, sdk.NewCoins(msg.Amount),
	); err != nil {
		return nil, err
	}

	// Extend paid_until_height.
	periods := msg.Amount.Amount.Quo(params.MinEscrowAmount).Uint64()
	record.PaidUntilHeight += periods * params.PruneInterval
	record.Amount = record.Amount.Add(msg.Amount)

	if err := ms.k.SetEscrowRecord(goCtx, record); err != nil {
		return nil, err
	}

	return &types.MsgRefillEscrowResponse{}, nil
}

// UpdateParams updates the module parameters. Governance-gated.
func (ms msgServer) UpdateParams(goCtx context.Context, msg *types.MsgUpdateParams) (*types.MsgUpdateParamsResponse, error) {
	if ms.k.authority != msg.Authority {
		return nil, govtypes.ErrInvalidSigner.Wrapf(
			"unauthorised: expected %s, got %s", ms.k.authority, msg.Authority,
		)
	}
	if err := msg.Params.Validate(); err != nil {
		return nil, err
	}
	if err := ms.k.SetParams(goCtx, msg.Params); err != nil {
		return nil, err
	}
	return &types.MsgUpdateParamsResponse{}, nil
}
