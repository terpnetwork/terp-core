package v6

import (
	"context"

	wasmtypes "github.com/CosmWasm/wasmd/x/wasm/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/module"
	upgradetypes "github.com/cosmos/cosmos-sdk/x/upgrade/types"

	"github.com/terpnetwork/terp-core/v6/app/keepers"
	"github.com/terpnetwork/terp-core/v6/app/upgrades"
)

// CreateV6UpgradeHandler migrates consensus/IBC module state from v0.53 + ibc-go
// v10 to v0.54 + ibc-go v11.1 via RunMigrations. In-flight PFM packets with
// nonrefundable=true will abort the ibc-go PFM v3→v4 migration — drain those
// before proposing this upgrade.
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
		logger.Info("starting v6 migrations (sdk 0.54, ibc-go v11.1, 08-wasm v11.1.0)")

		migrations, err := mm.RunMigrations(ctx, configurator, vm)
		if err != nil {
			return nil, err
		}

		// Circuit store/pin is a privileged host path; default to nobody after the bump.
		if keepers != nil && keepers.WasmKeeper != nil {
			params := keepers.WasmKeeper.GetParams(ctx)
			params.CircuitUploadAccess = wasmtypes.AllowNobody
			if err := keepers.WasmKeeper.SetParams(ctx, params); err != nil {
				return nil, err
			}
		}

		logger.Info("v6 migrations complete")
		return migrations, nil
	}
}
