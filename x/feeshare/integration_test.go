package feeshare_test

import (
	"encoding/json"
	"path/filepath"
	"testing"

	"cosmossdk.io/log"
	wasmkeeper "github.com/CosmWasm/wasmd/x/wasm/keeper"
	abci "github.com/cometbft/cometbft/abci/types"
	cosmosdb "github.com/cosmos/cosmos-db"
	"github.com/stretchr/testify/require"

	"cosmossdk.io/store/snapshots"
	snapshottypes "cosmossdk.io/store/snapshots/types"
	bam "github.com/cosmos/cosmos-sdk/baseapp"
	simtestutil "github.com/cosmos/cosmos-sdk/testutil/sims"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/x/mint/types"

	terpapp "github.com/terpnetwork/terp-core/v4/app"
)

// returns context and an app with updated mint keeper
func CreateTestApp(t *testing.T, isCheckTx bool) (*terpapp.TerpApp, sdk.Context) {
	app := Setup(t, isCheckTx)

	ctx := app.BaseApp.NewContext(isCheckTx)
	if err := app.AppKeepers.MintKeeper.Params.Set(ctx, types.DefaultParams()); err != nil {
		panic(err)
	}
	app.AppKeepers.MintKeeper.Minter.Set(ctx, types.DefaultInitialMinter())

	return app, ctx
}

func Setup(t *testing.T, isCheckTx bool) *terpapp.TerpApp {
	app, genesisState := GenApp(t, !isCheckTx)
	if !isCheckTx {
		// init chain must be called to stop deliverState from being nil
		stateBytes, err := json.MarshalIndent(genesisState, "", " ")
		if err != nil {
			panic(err)
		}

		// Initialize the chain
		app.InitChain(
			&abci.RequestInitChain{
				Validators: []abci.ValidatorUpdate{},
				// ConsensusParams: &tmproto.ConsensusParams{},
				ConsensusParams: simtestutil.DefaultConsensusParams,
				AppStateBytes:   stateBytes,
				ChainId:         "testing",
			},
		)
	}

	return app
}

func GenApp(t *testing.T, withGenesis bool, opts ...wasmkeeper.Option) (*terpapp.TerpApp, terpapp.GenesisState) {
	db := cosmosdb.NewMemDB()
	nodeHome := t.TempDir()
	snapshotDir := filepath.Join(nodeHome, "data", "snapshots")

	snapshotDB, err := cosmosdb.NewGoLevelDB("metadata", snapshotDir, nil)
	if err != nil {
		panic(err)
	}
	require.NoError(t, err)
	t.Cleanup(func() { snapshotDB.Close() })
	snapshotStore, err := snapshots.NewStore(snapshotDB, snapshotDir)
	require.NoError(t, err)

	app := terpapp.NewTerpApp(
		log.NewNopLogger(),
		db,
		nil,
		true,
		simtestutil.EmptyAppOptions{},
		opts,
		bam.SetChainID("testing"),
		bam.SetSnapshot(snapshotStore, snapshottypes.SnapshotOptions{KeepRecent: 2}),
	)

	if withGenesis {
		return app, terpapp.NewDefaultGenesisState(app.AppCodec())
	}

	return app, terpapp.GenesisState{}
}
