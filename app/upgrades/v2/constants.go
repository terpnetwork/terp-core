package v2

import (
	store "github.com/cosmos/cosmos-sdk/store/types"
	packetforwardtypes "github.com/strangelove-ventures/packet-forward-middleware/v7/router/types"
	"github.com/terpnetwork/terp-core/v2/app/upgrades"
	ibchookstypes "github.com/terpnetwork/terp-core/v2/x/ibchooks/types"
)

// UpgradeName defines the on-chain upgrade name for the upgrade.
const UpgradeName = "v2"

var Upgrade = upgrades.Upgrade{
	UpgradeName:          UpgradeName,
	CreateUpgradeHandler: CreateV2UpgradeHandler,
	StoreUpgrades: store.StoreUpgrades{
		Added: []string{
			ibchookstypes.StoreKey,
			packetforwardtypes.StoreKey,
		},
	},
}
