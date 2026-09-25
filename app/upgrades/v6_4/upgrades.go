package v6_4

import (
	"context"
	"fmt"
	"sort"
	"strings"

	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/module"
	upgradetypes "github.com/cosmos/cosmos-sdk/x/upgrade/types"

	"github.com/terpnetwork/terp-core/v6/app/iavl"
	"github.com/terpnetwork/terp-core/v6/app/keepers"
	"github.com/terpnetwork/terp-core/v6/app/upgrades"
)

// CreateUpgradeHandler finishes Upgrade B: keepers are already wired to dest
// trees on this ELF. Live SHA-256 migratable names are Deleted from
// CommitInfo. IBC stays SHA-256. No further plan is armed.
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

		if keepers == nil {
			return nil, fmt.Errorf("v6.4: keepers required")
		}
		for _, src := range iavl.MigratableStores() {
			if keepers.GetKey(src) != nil {
				return nil, fmt.Errorf("v6.4: live SHA-256 name %s still mounted; this ELF must omit it", src)
			}
			dst := iavl.DestName(src)
			if keepers.GetKey(dst) == nil {
				return nil, fmt.Errorf("v6.4: dest %s missing", dst)
			}
		}
		if keepers.GetKey("ibc") == nil {
			return nil, fmt.Errorf("v6.4: ibc store missing")
		}
		if keepers.GetKey("b3-ibc") != nil {
			return nil, fmt.Errorf("v6.4: refusing IBC dest tree")
		}

		names := make([]string, 0, len(keepers.GetKVStoreKey()))
		for n := range keepers.GetKVStoreKey() {
			names = append(names, n)
		}
		sort.Strings(names)
		logger.Info("v6.4: keepers on dest trees; dropping live SHA-256 migratable names", "keys", strings.Join(names, ","))

		logger.Info("v6.4: running module migrations")
		migrations, err := mm.RunMigrations(ctx, configurator, vm)
		if err != nil {
			return nil, err
		}
		logger.Info("v6.4: ibc/transfer/ica stores unchanged (sha256)")
		return migrations, nil
	}
}
