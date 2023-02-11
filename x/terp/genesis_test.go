package terp_test

import (
	"testing"

	"github.com/stretchr/testify/require"
	keepertest "github.com/terpnetwork/terp-core/testutil/keeper"
	"github.com/terpnetwork/terp-core/testutil/nullify"
	"github.com/terpnetwork/terp-core/x/terp"
	"github.com/terpnetwork/terp-core/x/terp/types"
)

func TestGenesis(t *testing.T) {
	genesisState := types.GenesisState{
		Params: types.DefaultParams(),

		TerpidList: []types.Terpid{
			{
				Id: 0,
			},
			{
				Id: 1,
			},
		},
		TerpidCount: 2,
		SupplychainList: []types.Supplychain{
			{
				Id: 0,
			},
			{
				Id: 1,
			},
		},
		SupplychainCount: 2,
		// this line is used by starport scaffolding # genesis/test/state
	}

	k, ctx := keepertest.TerpKeeper(t)
	terp.InitGenesis(ctx, *k, genesisState)
	got := terp.ExportGenesis(ctx, *k)
	require.NotNil(t, got)

	nullify.Fill(&genesisState)
	nullify.Fill(got)

	require.ElementsMatch(t, genesisState.TerpidList, got.TerpidList)
	require.Equal(t, genesisState.TerpidCount, got.TerpidCount)
	require.ElementsMatch(t, genesisState.SupplychainList, got.SupplychainList)
	require.Equal(t, genesisState.SupplychainCount, got.SupplychainCount)
	// this line is used by starport scaffolding # genesis/test/assert
}
