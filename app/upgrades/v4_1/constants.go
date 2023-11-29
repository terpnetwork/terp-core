package v4_1

import (
	store "github.com/cosmos/cosmos-sdk/store/types"
	"github.com/terpnetwork/terp-core/v4/app/upgrades"
	clocktypes "github.com/terpnetwork/terp-core/v4/x/clock/types"
	driptypes "github.com/terpnetwork/terp-core/v4/x/drip/types"
)

// UpgradeName defines the on-chain upgrade name for the Terp v4 upgrade.
const UpgradeName = "v4.1.0"

var Upgrade = upgrades.Upgrade{
	UpgradeName:          UpgradeName,
	CreateUpgradeHandler: CreateV4_1UpgradeHandler,
	StoreUpgrades: store.StoreUpgrades{
		Added: []string{
			driptypes.ModuleName,
			clocktypes.ModuleName,
		},
	},
}
