package v4

import (
	"github.com/terpnetwork/terp-core/v2/app/upgrades"

	store "github.com/cosmos/cosmos-sdk/store/types"
	clocktypes "github.com/terpnetwork/terp-core/v2/x/clock/types"
)

// UpgradeName defines the on-chain upgrade name for the Terp v4 upgrade.
const UpgradeName = "v4"

var Upgrade = upgrades.Upgrade{
	UpgradeName:          UpgradeName,
	CreateUpgradeHandler: CreateV4UpgradeHandler,
	StoreUpgrades: store.StoreUpgrades{
		Added: []string{
			clocktypes.ModuleName,
		},
	},
}
