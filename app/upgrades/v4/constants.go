package v4

import (
	"github.com/terpnetwork/terp-core/v4/app/upgrades"

	store "cosmossdk.io/store/types"
)

// UpgradeName defines the on-chain upgrade name for the Terp v4 upgrade.
const UpgradeName = "v4"

var Upgrade = upgrades.Upgrade{
	UpgradeName:          UpgradeName,
	CreateUpgradeHandler: CreateV4UpgradeHandler,
	StoreUpgrades:        store.StoreUpgrades{},
}
