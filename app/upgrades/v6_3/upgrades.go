package v6_3

import (
	"context"
	"fmt"

	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/module"
	upgradekeeper "github.com/cosmos/cosmos-sdk/x/upgrade/keeper"
	upgradetypes "github.com/cosmos/cosmos-sdk/x/upgrade/types"

	"github.com/terpnetwork/terp-core/v6/app/iavl"
	"github.com/terpnetwork/terp-core/v6/app/keepers"
	"github.com/terpnetwork/terp-core/v6/app/upgrades"
)

// CreateUpgradeHandler copies every migratable IAVL store into its Added
// b3-* dest. IBC-facing stores and 08-wasm stay SHA-256. Arms plan v6.4 at
// BlockHeight()+2 so governance submits only v6.3.
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

		logger.Info("v6.3: running module migrations")
		migrations, err := mm.RunMigrations(ctx, configurator, vm)
		if err != nil {
			return nil, err
		}

		for _, p := range iavl.DualStorePairs() {
			srcName, dstName := p[0], p[1]
			if iavl.IsIBCStore(srcName) {
				return nil, fmt.Errorf("refusing to rehash IBC-facing store %s", srcName)
			}
			if keepers == nil {
				return nil, fmt.Errorf("v6.3: keepers required to copy %s", srcName)
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
			logger.Info("v6.3: curated store", "src", srcName, "dst", dstName, "keys", n)
		}

		logger.Info("v6.3: will arm plan v6.4 in EndBlocker (ApplyUpgrade clears the plan key)")
		logger.Info("v6.3: ibc/transfer/ica stores unchanged (sha256)")
		return migrations, nil
	}
}

// SyncDestFromLive recopies every migratable store into dest, deleting dest-only
// keys. Live keepers still write through EndBlock of the apply height and the
// gap block; v6.4 Deletes those live trees, so dest must match the last live commit.
func SyncDestFromLive(ctx sdk.Context, k *keepers.AppKeepers) error {
	if k == nil {
		return nil
	}
	logger := ctx.Logger().With("upgrade", UpgradeName)
	for _, p := range iavl.DualStorePairs() {
		srcName, dstName := p[0], p[1]
		if iavl.IsIBCStore(srcName) {
			return fmt.Errorf("refusing to rehash IBC-facing store %s", srcName)
		}
		srcKey := k.GetKey(srcName)
		dstKey := k.GetKey(dstName)
		if srcKey == nil || dstKey == nil {
			continue
		}
		n, del, err := syncKVStore(ctx, srcKey, dstKey)
		if err != nil {
			return fmt.Errorf("sync %s -> %s: %w", srcName, dstName, err)
		}
		logger.Info("v6.3: synced dest", "src", srcName, "dst", dstName, "set", n, "deleted", del)
	}
	return nil
}

// SyncDestWhileArmed recopies dest after mm.EndBlock on every block while plan
// v6.4 is armed (apply height after MaybeArmNext, and the gap block).
func SyncDestWhileArmed(ctx sdk.Context, k *keepers.AppKeepers) error {
	if k == nil || k.UpgradeKeeper == nil {
		return nil
	}
	plan, err := k.UpgradeKeeper.GetUpgradePlan(ctx)
	if err != nil {
		return nil
	}
	if plan.Name != NextUpgradeName {
		return nil
	}
	return SyncDestFromLive(ctx, k)
}

// MaybeArmNext schedules v6.4 after v6.3 ApplyUpgrade has cleared the plan key.
// Call from TerpApp.EndBlocker on the apply block.
func MaybeArmNext(ctx sdk.Context, k *upgradekeeper.Keeper) error {
	if k == nil {
		return nil
	}
	done, err := k.GetDoneHeight(ctx, UpgradeName)
	if err != nil {
		return err
	}
	if done != ctx.BlockHeight() {
		return nil
	}
	if _, err := k.GetUpgradePlan(ctx); err == nil {
		return nil
	}
	next := upgradetypes.Plan{
		Name:   NextUpgradeName,
		Height: ctx.BlockHeight() + NextUpgradeGap,
		Info:   NextUpgradeInfo,
	}
	if err := k.ScheduleUpgrade(ctx, next); err != nil {
		return fmt.Errorf("arm %s: %w", NextUpgradeName, err)
	}
	ctx.Logger().With("upgrade", UpgradeName).Info("v6.3: armed plan v6.4", "height", next.Height, "info", next.Info)
	return nil
}
