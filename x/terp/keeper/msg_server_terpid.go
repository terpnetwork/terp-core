package keeper

import (
	"context"
	"fmt"

	"github.com/terpnetwork/terp-core/x/terp/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
	sdkerrors "github.com/cosmos/cosmos-sdk/types/errors"
)

func (k msgServer) CreateTerpid(goCtx context.Context, msg *types.MsgCreateTerpid) (*types.MsgCreateTerpidResponse, error) {
	ctx := sdk.UnwrapSDKContext(goCtx)

	terpid := types.Terpid{
		Creator: msg.Creator,
		Terpid:  msg.Terpid,
		Address: msg.Address,
	}

	id := k.AppendTerpid(
		ctx,
		terpid,
	)

	return &types.MsgCreateTerpidResponse{
		Id: id,
	}, nil
}

func (k msgServer) UpdateTerpid(goCtx context.Context, msg *types.MsgUpdateTerpid) (*types.MsgUpdateTerpidResponse, error) {
	ctx := sdk.UnwrapSDKContext(goCtx)

	terpid := types.Terpid{
		Creator: msg.Creator,
		Id:      msg.Id,
		Terpid:  msg.Terpid,
		Address: msg.Address,
	}

	// Checks that the element exists
	val, found := k.GetTerpid(ctx, msg.Id)
	if !found {
		return nil, sdkerrors.Wrap(sdkerrors.ErrKeyNotFound, fmt.Sprintf("key %d doesn't exist", msg.Id))
	}

	// Checks if the msg creator is the same as the current owner
	if msg.Creator != val.Creator {
		return nil, sdkerrors.Wrap(sdkerrors.ErrUnauthorized, "incorrect owner")
	}

	k.SetTerpid(ctx, terpid)

	return &types.MsgUpdateTerpidResponse{}, nil
}

func (k msgServer) DeleteTerpid(goCtx context.Context, msg *types.MsgDeleteTerpid) (*types.MsgDeleteTerpidResponse, error) {
	ctx := sdk.UnwrapSDKContext(goCtx)

	// Checks that the element exists
	val, found := k.GetTerpid(ctx, msg.Id)
	if !found {
		return nil, sdkerrors.Wrap(sdkerrors.ErrKeyNotFound, fmt.Sprintf("key %d doesn't exist", msg.Id))
	}

	// Checks if the msg creator is the same as the current owner
	if msg.Creator != val.Creator {
		return nil, sdkerrors.Wrap(sdkerrors.ErrUnauthorized, "incorrect owner")
	}

	k.RemoveTerpid(ctx, msg.Id)

	return &types.MsgDeleteTerpidResponse{}, nil
}
