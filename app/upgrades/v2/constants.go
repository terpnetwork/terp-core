package v2

import (
	packetforwardtypes "github.com/strangelove-ventures/packet-forward-middleware/v7/router/types"

	store "github.com/cosmos/cosmos-sdk/store/types"

	"github.com/terpnetwork/terp-core/v2/app/upgrades"
	feesharetypes "github.com/terpnetwork/terp-core/v2/x/feeshare/types"
	"github.com/terpnetwork/terp-core/v2/x/globalfee"
	ibchookstypes "github.com/terpnetwork/terp-core/v2/x/ibchooks/types"
)

// UpgradeName defines the on-chain upgrade name for the upgrade.
const UpgradeName = "v2.0.0"

var Upgrade = upgrades.Upgrade{
	UpgradeName:          UpgradeName,
	CreateUpgradeHandler: CreateV2UpgradeHandler,
	StoreUpgrades: store.StoreUpgrades{
		Added: []string{
			globalfee.ModuleName,
			ibchookstypes.StoreKey,
			packetforwardtypes.StoreKey,
			feesharetypes.ModuleName,
		},
	},
}