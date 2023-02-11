package keeper_test

import (
	"testing"

	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/stretchr/testify/require"
	keepertest "github.com/terpnetwork/terp-core/testutil/keeper"
	"github.com/terpnetwork/terp-core/testutil/nullify"
	"github.com/terpnetwork/terp-core/x/terp/keeper"
	"github.com/terpnetwork/terp-core/x/terp/types"
)

func createNTerpid(keeper *keeper.Keeper, ctx sdk.Context, n int) []types.Terpid {
	items := make([]types.Terpid, n)
	for i := range items {
		items[i].Id = keeper.AppendTerpid(ctx, items[i])
	}
	return items
}

func TestTerpidGet(t *testing.T) {
	keeper, ctx := keepertest.TerpKeeper(t)
	items := createNTerpid(keeper, ctx, 10)
	for _, item := range items {
		got, found := keeper.GetTerpid(ctx, item.Id)
		require.True(t, found)
		require.Equal(t,
			nullify.Fill(&item),
			nullify.Fill(&got),
		)
	}
}

func TestTerpidRemove(t *testing.T) {
	keeper, ctx := keepertest.TerpKeeper(t)
	items := createNTerpid(keeper, ctx, 10)
	for _, item := range items {
		keeper.RemoveTerpid(ctx, item.Id)
		_, found := keeper.GetTerpid(ctx, item.Id)
		require.False(t, found)
	}
}

func TestTerpidGetAll(t *testing.T) {
	keeper, ctx := keepertest.TerpKeeper(t)
	items := createNTerpid(keeper, ctx, 10)
	require.ElementsMatch(t,
		nullify.Fill(items),
		nullify.Fill(keeper.GetAllTerpid(ctx)),
	)
}

func TestTerpidCount(t *testing.T) {
	keeper, ctx := keepertest.TerpKeeper(t)
	items := createNTerpid(keeper, ctx, 10)
	count := uint64(len(items))
	require.Equal(t, count, keeper.GetTerpidCount(ctx))
}
