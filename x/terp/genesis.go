package terp

import (
	"github.com/terpnetwork/terp-core/x/terp/keeper"
	"github.com/terpnetwork/terp-core/x/terp/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
)

// InitGenesis initializes the capability module's state from a provided genesis
// state.
func InitGenesis(ctx sdk.Context, k keeper.Keeper, genState types.GenesisState) {
	// Set all the terpid
	for _, elem := range genState.TerpidList {
		k.SetTerpid(ctx, elem)
	}

	// Set terpid count
	k.SetTerpidCount(ctx, genState.TerpidCount)
	// Set all the supplychain
	for _, elem := range genState.SupplychainList {
		k.SetSupplychain(ctx, elem)
	}

	// Set supplychain count
	k.SetSupplychainCount(ctx, genState.SupplychainCount)
	// this line is used by starport scaffolding # genesis/module/init
	k.SetParams(ctx, genState.Params)
}

// ExportGenesis returns the capability module's exported genesis.
func ExportGenesis(ctx sdk.Context, k keeper.Keeper) *types.GenesisState {
	genesis := types.DefaultGenesis()
	genesis.Params = k.GetParams(ctx)

	genesis.TerpidList = k.GetAllTerpid(ctx)
	genesis.TerpidCount = k.GetTerpidCount(ctx)
	genesis.SupplychainList = k.GetAllSupplychain(ctx)
	genesis.SupplychainCount = k.GetSupplychainCount(ctx)
	// this line is used by starport scaffolding # genesis/module/export

	return genesis
}
