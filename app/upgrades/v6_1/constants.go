package v6_1

import (
	store "github.com/cosmos/cosmos-sdk/store/v2/types"

	"github.com/terpnetwork/terp-core/v6/app/iavlhash"
	"github.com/terpnetwork/terp-core/v6/app/upgrades"
)

// UpgradeName is the on-chain plan name. Validators put this in the
// SoftwareUpgrade proposal. TSH: make tsh-upgrade-v61.
const UpgradeName = "v6.1"

var Upgrade = upgrades.Upgrade{
	UpgradeName:          UpgradeName,
	CreateUpgradeHandler: CreateUpgradeHandler,
	StoreUpgrades: store.StoreUpgrades{
		Added: []string{
			iavlhash.BankB3,
			iavlhash.StakingB3,
			iavlhash.AuthB3,
		},
		Deleted: []string{
			// x/params stays mounted for this upgrade so the handler can copy
			// leftover subspace values. Keys are wiped in the handler.
			// Unmount in a later upgrade.
			"protocolpool",
		},
	},
}
