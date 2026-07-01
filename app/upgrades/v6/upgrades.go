package v6

import (
	"context"

	upgradetypes "cosmossdk.io/x/upgrade/types"
	wasmtypes "github.com/CosmWasm/wasmd/x/wasm/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/module"
	"github.com/terpnetwork/terp-core/v5/app/keepers"
	"github.com/terpnetwork/terp-core/v5/app/upgrades"
	tftypes "github.com/terpnetwork/terp-core/v5/x/tokenfactory/types"
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

		// Set default tokenfactory params explicity
		keepers.TokenFactoryKeeper.SetParams(ctx, tftypes.DefaultParams())

		// set terp foundation dao with access to upload circuits for now.
		wasmParams := keepers.WasmKeeper.GetParams(ctx)
		wasmParams.CircuitUploadAccess = wasmtypes.AccessTypeAnyOfAddresses.With(sdk.MustAccAddressFromBech32("terp14w2qva6dx6wcsmq5fvplh7cr7nvptejznyvpe5hp5mtyqhxxjamsz3kw2w"))
		keepers.WasmKeeper.SetParams(ctx, wasmParams)
		logger.Info("v6 upgrade complete — x/hashmerchant module added, ")
		return migrations, nil
	}
}
