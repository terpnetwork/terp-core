package keeper_test

import (
	"crypto/sha256"
	"os"
	"testing"
	"time"

	"github.com/terpnetwork/terp-core/x/wasm/types"

	"github.com/stretchr/testify/assert"

	cryptocodec "github.com/cosmos/cosmos-sdk/crypto/codec"
	"github.com/cosmos/cosmos-sdk/crypto/keys/ed25519"
	sdk "github.com/cosmos/cosmos-sdk/types"
	authtypes "github.com/cosmos/cosmos-sdk/x/auth/types"
	banktypes "github.com/cosmos/cosmos-sdk/x/bank/types"
	"github.com/stretchr/testify/require"
	tmproto "github.com/tendermint/tendermint/proto/tendermint/types"
	tmtypes "github.com/tendermint/tendermint/types"

	"github.com/terpnetwork/terp-core/app"
	"github.com/terpnetwork/terp-core/x/wasm/keeper"
)

func TestSnapshotter(t *testing.T) {
	specs := map[string]struct {
		wasmFiles []string
	}{
		"single contract": {
			wasmFiles: []string{"./testdata/reflect.wasm"},
		},
		"multiple contract": {
			wasmFiles: []string{"./testdata/reflect.wasm", "./testdata/burner.wasm", "./testdata/reflect.wasm"},
		},
		"duplicate contracts": {
			wasmFiles: []string{"./testdata/reflect.wasm", "./testdata/reflect.wasm"},
		},
	}
	for name, spec := range specs {
		t.Run(name, func(t *testing.T) {
			// setup source app
			srcTerpApp, genesisAddr := newWasmExampleApp(t)

			// store wasm codes on chain
			ctx := srcTerpApp.NewUncachedContext(false, tmproto.Header{
				ChainID: "foo",
				Height:  srcTerpApp.LastBlockHeight() + 1,
				Time:    time.Now(),
			})
			wasmKeeper := app.NewTestSupport(t, srcTerpApp).WasmKeeper()
			contractKeeper := keeper.NewDefaultPermissionKeeper(&wasmKeeper)

			srcCodeIDToChecksum := make(map[uint64][]byte, len(spec.wasmFiles))
			for i, v := range spec.wasmFiles {
				wasmCode, err := os.ReadFile(v)
				require.NoError(t, err)
				codeID, checksum, err := contractKeeper.Create(ctx, genesisAddr, wasmCode, nil)
				require.NoError(t, err)
				require.Equal(t, uint64(i+1), codeID)
				srcCodeIDToChecksum[codeID] = checksum
			}
			// create snapshot
			srcTerpApp.Commit()
			snapshotHeight := uint64(srcTerpApp.LastBlockHeight())
			snapshot, err := srcTerpApp.SnapshotManager().Create(snapshotHeight)
			require.NoError(t, err)
			assert.NotNil(t, snapshot)

			// when snapshot imported into dest app instance
			destTerpApp := app.SetupWithEmptyStore(t)
			require.NoError(t, destTerpApp.SnapshotManager().Restore(*snapshot))
			for i := uint32(0); i < snapshot.Chunks; i++ {
				chunkBz, err := srcTerpApp.SnapshotManager().LoadChunk(snapshot.Height, snapshot.Format, i)
				require.NoError(t, err)
				end, err := destTerpApp.SnapshotManager().RestoreChunk(chunkBz)
				require.NoError(t, err)
				if end {
					break
				}
			}

			// then all wasm contracts are imported
			wasmKeeper = app.NewTestSupport(t, destTerpApp).WasmKeeper()
			ctx = destTerpApp.NewUncachedContext(false, tmproto.Header{
				ChainID: "foo",
				Height:  destTerpApp.LastBlockHeight() + 1,
				Time:    time.Now(),
			})

			destCodeIDToChecksum := make(map[uint64][]byte, len(spec.wasmFiles))
			wasmKeeper.IterateCodeInfos(ctx, func(id uint64, info types.CodeInfo) bool {
				bz, err := wasmKeeper.GetByteCode(ctx, id)
				require.NoError(t, err)
				hash := sha256.Sum256(bz)
				destCodeIDToChecksum[id] = hash[:]
				assert.Equal(t, hash[:], info.CodeHash)
				return false
			})
			assert.Equal(t, srcCodeIDToChecksum, destCodeIDToChecksum)
		})
	}
}

func newWasmExampleApp(t *testing.T) (*app.TerpApp, sdk.AccAddress) {
	senderPrivKey := ed25519.GenPrivKey()
	pubKey, err := cryptocodec.ToTmPubKeyInterface(senderPrivKey.PubKey())
	require.NoError(t, err)

	senderAddr := senderPrivKey.PubKey().Address().Bytes()
	acc := authtypes.NewBaseAccount(senderAddr, senderPrivKey.PubKey(), 0, 0)
	amount, ok := sdk.NewIntFromString("10000000000000000000")
	require.True(t, ok)

	balance := banktypes.Balance{
		Address: acc.GetAddress().String(),
		Coins:   sdk.NewCoins(sdk.NewCoin(sdk.DefaultBondDenom, amount)),
	}
	validator := tmtypes.NewValidator(pubKey, 1)
	valSet := tmtypes.NewValidatorSet([]*tmtypes.Validator{validator})
	wasmApp := app.SetupWithGenesisValSet(t, valSet, []authtypes.GenesisAccount{acc}, "testing", nil, balance)

	return wasmApp, senderAddr
}
