package v1

import (
	store "github.com/cosmos/cosmos-sdk/store/types"

	"github.com/terpnetwork/terp-core/v2/app/upgrades"
)

const UpgradeName = "v1"

var Upgrade = upgrades.Upgrade{
	UpgradeName:          UpgradeName,
	CreateUpgradeHandler: CreateV1UpgradeHandler,
	StoreUpgrades:        store.StoreUpgrades{},
}
