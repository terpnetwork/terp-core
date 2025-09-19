package v5

import (
	store "cosmossdk.io/store/types"
	circuittypes "cosmossdk.io/x/circuit/types"
	"github.com/terpnetwork/terp-core/v4/app/upgrades"
	smartaccounttypes "github.com/terpnetwork/terp-core/v4/x/smart-account/types"
)

const UpgradeName = "v5"

var Upgrade = upgrades.Upgrade{
	UpgradeName:          UpgradeName,
	CreateUpgradeHandler: CreateV5UpgradeHandler,
	StoreUpgrades: store.StoreUpgrades{
		Added: []string{
			circuittypes.ModuleName,
			smartaccounttypes.ModuleName,
		},
		Deleted: []string{
			"interchainquery",
			"capability",
			"ibcfee",
			"clock",
		},
	},
}
