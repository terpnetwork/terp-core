package v6

import (
	"context"

	upgradetypes "cosmossdk.io/x/upgrade/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/module"
	"github.com/terpnetwork/terp-core/v5/app/keepers"
	"github.com/terpnetwork/terp-core/v5/app/upgrades"
	hashmerchanttypes "github.com/terpnetwork/terp-core/v5/x/hashmerchant/types"
)

func CreateV6UpgradeHandler(
	mm *module.Manager,
	configurator module.Configurator,
	_ upgrades.BaseAppParamManager,
	keepers *keepers.AppKeepers,
	_ string,
) upgradetypes.UpgradeHandler {
	return func(goCtx context.Context, plan upgradetypes.Plan, vm module.VersionMap) (module.VersionMap, error) {
		ctx := sdk.UnwrapSDKContext(goCtx)
		logger := ctx.Logger().With("upgrade", UpgradeName)

		// Run migrations (this initialises the hashmerchant module genesis).
		migrations, err := mm.RunMigrations(ctx, configurator, vm)
		if err != nil {
			return nil, err
		}

		// Set default hashmerchant params explicitly (belt-and-suspenders).
		if err := keepers.HashMerchantKeeper.SetParams(ctx, hashmerchanttypes.DefaultParams()); err != nil {
			return nil, err
		}

		logger.Info("v6 upgrade complete — x/hashmerchant module added")
		return migrations, nil
	}
}
