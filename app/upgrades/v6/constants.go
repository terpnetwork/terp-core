package v6

import (
	store "github.com/cosmos/cosmos-sdk/store/v2/types"

	"github.com/terpnetwork/terp-core/v6/app/upgrades"
)

// UpgradeName is the on-chain software upgrade plan name for SDK 0.54 + ibc-go v11.1.
const UpgradeName = "v6"

var Upgrade = upgrades.Upgrade{
	UpgradeName:          UpgradeName,
	CreateUpgradeHandler: CreateV6UpgradeHandler,
	StoreUpgrades: store.StoreUpgrades{
		Added: []string{"cw-hooks", "hashmerchant"},
		// remove group, nft,
		Deleted: []string{"group", "nft"},
	},
}
