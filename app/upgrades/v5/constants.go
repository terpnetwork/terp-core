package v5

import (
	store "github.com/cosmos/cosmos-sdk/store/v2/types"
	circuittypes "github.com/cosmos/cosmos-sdk/contrib/x/circuit/types"
	wasmlctypes "github.com/cosmos/ibc-go/modules/light-clients/08-wasm/v11/types"
	"github.com/terpnetwork/terp-core/v6/app/upgrades"
	smartaccounttypes "github.com/terpnetwork/terp-core/v6/x/smart-account/types"
)

const UpgradeName = "v5"

var Upgrade = upgrades.Upgrade{
	UpgradeName:          UpgradeName,
	CreateUpgradeHandler: CreateV5UpgradeHandler,
	StoreUpgrades: store.StoreUpgrades{
		Added: []string{
			circuittypes.ModuleName,
			smartaccounttypes.ModuleName,
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
