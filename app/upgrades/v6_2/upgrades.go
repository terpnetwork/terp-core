package v6_2

import (
	"context"
	"sort"
	"strings"

	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/module"
	upgradetypes "github.com/cosmos/cosmos-sdk/x/upgrade/types"

	"github.com/terpnetwork/terp-core/v6/app/iavlhash"
	"github.com/terpnetwork/terp-core/v6/app/keepers"
	"github.com/terpnetwork/terp-core/v6/app/upgrades"
)

// CreateUpgradeHandler finishes Upgrade B: keepers stay on bank/staking/acc
// (live IAVL, including writes after v6.1). Dest b3-* trees are not remounted,
// so they drop out of CommitInfo on this block's commit. IBC stays SHA-256.
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

		logger.Info("v6.2: dropping unmounted b3-* dest trees from CommitInfo; keepers remain bank/staking/acc")
		if keepers != nil {
			for _, p := range iavlhash.DualStorePairs() {
				if keepers.GetKey(p[1]) != nil {
					logger.Error("v6.2: dest key still mounted; suffix would remain", "dst", p[1])
				}
			}
			names := make([]string, 0, len(keepers.GetKVStoreKey()))
			for n := range keepers.GetKVStoreKey() {
				names = append(names, n)
			}
			sort.Strings(names)
			logger.Info("v6.2: mounted store keys", "keys", strings.Join(names, ","))
		}

		logger.Info("v6.2: running module migrations")
		migrations, err := mm.RunMigrations(ctx, configurator, vm)
		if err != nil {
			return nil, err
		}
		logger.Info("v6.2: ibc/transfer/ica stores unchanged (sha256)")
		return migrations, nil
	}
}
