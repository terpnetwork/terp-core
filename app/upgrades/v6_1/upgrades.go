package v6_1

import (
	"context"
	"fmt"

	wasmtypes "github.com/CosmWasm/wasmd/x/wasm/types"
	storetypes "github.com/cosmos/cosmos-sdk/store/v2/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/module"
	upgradetypes "github.com/cosmos/cosmos-sdk/x/upgrade/types"

	"github.com/terpnetwork/terp-core/v6/app/iavlhash"
	"github.com/terpnetwork/terp-core/v6/app/keepers"
	"github.com/terpnetwork/terp-core/v6/app/upgrades"
)

// CreateUpgradeHandler copies every migratable IAVL store into its Added
// b3-* dest (iavlhash.MigratableStores). IBC-facing stores and 08-wasm stay
// SHA-256. Upgrade B is plan v6.2 on feat/6.2.0-dev (separate worktree).
func CreateUpgradeHandler(
	mm *module.Manager,
	configurator module.Configurator,
	_ upgrades.BaseAppParamManager,
	keepers *keepers.AppKeepers,
	_ string,
) upgradetypes.UpgradeHandler {
	return func(goCtx context.Context, plan upgradetypes.Plan, vm module.VersionMap) (module.VersionMap, error) {
		ctx := sdk.UnwrapSDKContext(goCtx)
		logger := ctx.Logger().With("upgrade", UpgradeName)
		logger.Info("v6.1: copying leftover x/params subspace values into module stores")
		if err := migrateLegacyParams(ctx, keepers); err != nil {
			return nil, err
		}

		logger.Info("v6.1: running module migrations (SDK 0.55 / CometBFT 0.40)")
		migrations, err := mm.RunMigrations(ctx, configurator, vm)
		if err != nil {
			return nil, err
		}

		// Circuit store/pin stays privileged (AllowNobody). ACL / deposit is the upload path.
		// 50% circuit maintenance share → Foundation DAO (gov 56), not circuit_dev_pool.
		if keepers != nil && keepers.WasmKeeper != nil {
			params := keepers.WasmKeeper.GetParams(ctx)
			params.CircuitUploadAccess = wasmtypes.AllowNobody
			params.CircuitDevDestination = FoundationDAOAddr
			if err := keepers.WasmKeeper.SetParams(ctx, params); err != nil {
				return nil, err
			}
			logger.Info("v6.1: circuit_dev_destination", "addr", FoundationDAOAddr)
		}

		for _, p := range iavlhash.DualStorePairs() {
			srcName, dstName := p[0], p[1]
			if iavlhash.AlgorithmName(srcName) == "sha256" {
				return nil, fmt.Errorf("refusing to rehash IBC-facing store %s", srcName)
			}
			if keepers == nil {
				return nil, fmt.Errorf("v6.1: keepers required to copy %s", srcName)
			}
			srcKey := keepers.GetKey(srcName)
			dstKey := keepers.GetKey(dstName)
			if srcKey == nil || dstKey == nil {
				return nil, fmt.Errorf("missing dual-store keys %s -> %s", srcName, dstName)
			}
			n, err := copyKVStore(ctx, srcKey, dstKey)
			if err != nil {
				return nil, fmt.Errorf("copy %s -> %s: %w", srcName, dstName, err)
			}
			logger.Info("v6.1: curated store", "src", srcName, "dst", dstName, "keys", n)
		}

		logger.Info("v6.1: ibc/transfer/ica stores unchanged (sha256)")
		return migrations, nil
	}
}

func copyKVStore(ctx sdk.Context, srcKey, dstKey storetypes.StoreKey) (int, error) {
	src := ctx.KVStore(srcKey)
	dst := ctx.KVStore(dstKey)
	it := src.Iterator(nil, nil)
	defer it.Close()
	n := 0
	for ; it.Valid(); it.Next() {
		dst.Set(it.Key(), it.Value())
		n++
	}
	// cachekv Iterator.Error() is "invalid" once exhausted; do not treat that as failure.
	return n, nil
}
