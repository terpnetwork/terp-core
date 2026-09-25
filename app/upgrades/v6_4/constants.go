package v6_4

import (
	store "github.com/cosmos/cosmos-sdk/store/v2/types"

	"github.com/terpnetwork/terp-core/v6/app/iavl"
	"github.com/terpnetwork/terp-core/v6/app/upgrades"
)

// UpgradeName is the on-chain plan name. The v6.3 handler arms this at +2.
// Governance does not submit this plan.
const UpgradeName = "v6.4"

var Upgrade = upgrades.Upgrade{
	UpgradeName:          UpgradeName,
	CreateUpgradeHandler: CreateUpgradeHandler,
	// Drop live SHA-256 migratable names from CommitInfo. Keep dest b3-* as
	// the keeper stores. Do not Renamed dest onto bank/staking/acc.
	StoreUpgrades: store.StoreUpgrades{
		Deleted: iavl.MigratableStores(),
	},
}
