package v3

import (
	"github.com/terpnetwork/terp-core/v4/app/upgrades"

	store "cosmossdk.io/store/types"
)

// UpgradeName defines the on-chain upgrade name for the Osmosis v4 upgrade.
const UpgradeName = "v3"

var Upgrade = upgrades.Upgrade{
	UpgradeName:          UpgradeName,
	CreateUpgradeHandler: CreateV3UpgradeHandler,
	StoreUpgrades:        store.StoreUpgrades{},
}
