package keeper_test

import (
	"testing"

	"github.com/stretchr/testify/require"
	testkeeper "github.com/terpnetwork/terp-core/testutil/keeper"
	"github.com/terpnetwork/terp-core/x/terp/types"
)

func TestGetParams(t *testing.T) {
	k, ctx := testkeeper.TerpKeeper(t)
	params := types.DefaultParams()

	k.SetParams(ctx, params)

	require.EqualValues(t, params, k.GetParams(ctx))
}
