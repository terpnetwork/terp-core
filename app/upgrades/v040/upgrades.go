/*package v1

import (
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/module"
	upgradetypes "github.com/cosmos/cosmos-sdk/x/upgrade/types"
	"github.com/terpnetwork/terp-core/app/keepers"
)

// CreateV10UpgradeHandler makes an upgrade handler for v10 of Juno
func CreateV1UpgradeHandler(
	mm *module.Manager,
	cfg module.Configurator,
	keepers *keepers.AppKeepers,
) upgradetypes.UpgradeHandler {
	return func(ctx sdk.Context, _ upgradetypes.Plan, vm module.VersionMap) (module.VersionMap, error) {

		// mint module consensus version bumped
		return mm.RunMigrations(ctx, cfg, vm)
	}
}
*/