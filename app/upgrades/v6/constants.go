package v6

import (
	store "cosmossdk.io/store/types"
	"github.com/terpnetwork/terp-core/v5/app/upgrades"
	hashmerchanttypes "github.com/terpnetwork/terp-core/v5/x/hashmerchant/types"
)

const UpgradeName = "v6"

var Upgrade = upgrades.Upgrade{
	UpgradeName:          UpgradeName,
	CreateUpgradeHandler: CreateV6UpgradeHandler,
	StoreUpgrades: store.StoreUpgrades{
		Added: []string{
			hashmerchanttypes.StoreKey,
		},
	},
}
