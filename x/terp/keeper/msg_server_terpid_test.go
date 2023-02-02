package keeper_test

import (
	"testing"

	sdkerrors "github.com/cosmos/cosmos-sdk/types/errors"
	"github.com/stretchr/testify/require"

	"github.com/terpnetwork/terp-core/x/terp/types"
)

func TestTerpidMsgServerCreate(t *testing.T) {
	srv, ctx := setupMsgServer(t)
	creator := "A"
	for i := 0; i < 5; i++ {
		resp, err := srv.CreateTerpid(ctx, &types.MsgCreateTerpid{Creator: creator})
		require.NoError(t, err)
		require.Equal(t, i, int(resp.Id))
	}
}

func TestTerpidMsgServerUpdate(t *testing.T) {
	creator := "A"

	for _, tc := range []struct {
		desc    string
		request *types.MsgUpdateTerpid
		err     error
	}{
		{
			desc:    "Completed",
			request: &types.MsgUpdateTerpid{Creator: creator},
		},
		{
			desc:    "Unauthorized",
			request: &types.MsgUpdateTerpid{Creator: "B"},
			err:     sdkerrors.ErrUnauthorized,
		},
		{
			desc:    "Unauthorized",
			request: &types.MsgUpdateTerpid{Creator: creator, Id: 10},
			err:     sdkerrors.ErrKeyNotFound,
		},
	} {
		t.Run(tc.desc, func(t *testing.T) {
			srv, ctx := setupMsgServer(t)
			_, err := srv.CreateTerpid(ctx, &types.MsgCreateTerpid{Creator: creator})
			require.NoError(t, err)

			_, err = srv.UpdateTerpid(ctx, tc.request)
			if tc.err != nil {
				require.ErrorIs(t, err, tc.err)
			} else {
				require.NoError(t, err)
			}
		})
	}
}

func TestTerpidMsgServerDelete(t *testing.T) {
	creator := "A"

	for _, tc := range []struct {
		desc    string
		request *types.MsgDeleteTerpid
		err     error
	}{
		{
			desc:    "Completed",
			request: &types.MsgDeleteTerpid{Creator: creator},
		},
		{
			desc:    "Unauthorized",
			request: &types.MsgDeleteTerpid{Creator: "B"},
			err:     sdkerrors.ErrUnauthorized,
		},
		{
			desc:    "KeyNotFound",
			request: &types.MsgDeleteTerpid{Creator: creator, Id: 10},
			err:     sdkerrors.ErrKeyNotFound,
		},
	} {
		t.Run(tc.desc, func(t *testing.T) {
			srv, ctx := setupMsgServer(t)

			_, err := srv.CreateTerpid(ctx, &types.MsgCreateTerpid{Creator: creator})
			require.NoError(t, err)
			_, err = srv.DeleteTerpid(ctx, tc.request)
			if tc.err != nil {
				require.ErrorIs(t, err, tc.err)
			} else {
				require.NoError(t, err)
			}
		})
	}
}
