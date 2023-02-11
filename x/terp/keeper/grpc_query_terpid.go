package keeper

import (
	"context"

	"github.com/cosmos/cosmos-sdk/store/prefix"
	sdk "github.com/cosmos/cosmos-sdk/types"
	sdkerrors "github.com/cosmos/cosmos-sdk/types/errors"
	"github.com/cosmos/cosmos-sdk/types/query"
	"github.com/terpnetwork/terp-core/x/terp/types"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func (k Keeper) TerpidAll(c context.Context, req *types.QueryAllTerpidRequest) (*types.QueryAllTerpidResponse, error) {
	if req == nil {
		return nil, status.Error(codes.InvalidArgument, "invalid request")
	}

	var terpids []types.Terpid
	ctx := sdk.UnwrapSDKContext(c)

	store := ctx.KVStore(k.storeKey)
	terpidStore := prefix.NewStore(store, types.KeyPrefix(types.TerpidKey))

	pageRes, err := query.Paginate(terpidStore, req.Pagination, func(key []byte, value []byte) error {
		var terpid types.Terpid
		if err := k.cdc.Unmarshal(value, &terpid); err != nil {
			return err
		}

		terpids = append(terpids, terpid)
		return nil
	})
	if err != nil {
		return nil, status.Error(codes.Internal, err.Error())
	}

	return &types.QueryAllTerpidResponse{Terpid: terpids, Pagination: pageRes}, nil
}

func (k Keeper) Terpid(c context.Context, req *types.QueryGetTerpidRequest) (*types.QueryGetTerpidResponse, error) {
	if req == nil {
		return nil, status.Error(codes.InvalidArgument, "invalid request")
	}

	ctx := sdk.UnwrapSDKContext(c)
	terpid, found := k.GetTerpid(ctx, req.Id)
	if !found {
		return nil, sdkerrors.ErrKeyNotFound
	}

	return &types.QueryGetTerpidResponse{Terpid: terpid}, nil
}
