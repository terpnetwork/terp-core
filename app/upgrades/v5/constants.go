package v5

import (
	store "cosmossdk.io/store/types"
	circuittypes "cosmossdk.io/x/circuit/types"
	wasmlctypes "github.com/cosmos/ibc-go/modules/light-clients/08-wasm/v10/types"
	"github.com/terpnetwork/terp-core/v5/app/upgrades"
	sat "github.com/terpnetwork/terp-core/v5/x/smart-account/types"
)

const UpgradeName = "v5"

var Upgrade = upgrades.Upgrade{
	UpgradeName:          UpgradeName,
	CreateUpgradeHandler: CreateV5UpgradeHandler,
	StoreUpgrades: store.StoreUpgrades{
		Added: []string{
			circuittypes.ModuleName,
			sat.ModuleName,
			wasmlctypes.StoreKey,
		},
		Deleted: []string{
			"interchainquery",
			"capability",
			"ibcfee",
			"clock",
		},
	},
}
