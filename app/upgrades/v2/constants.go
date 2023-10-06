package v2

import (
	packetforwardtypes "github.com/cosmos/ibc-apps/middleware/packet-forward-middleware/v7/router/types"
	icqtypes "github.com/cosmos/ibc-apps/modules/async-icq/v7/types"
	ibchookstypes "github.com/cosmos/ibc-apps/modules/ibc-hooks/v7/types"

	feesharetypes "github.com/terpnetwork/terp-core/v2/x/feeshare/types"
	globalfeetypes "github.com/terpnetwork/terp-core/v2/x/globalfee/types"

	store "github.com/cosmos/cosmos-sdk/store/types"

	"github.com/terpnetwork/terp-core/v2/app/upgrades"
)

const UpgradeName = "v2"

var Upgrade = upgrades.Upgrade{
	UpgradeName:          UpgradeName,
	CreateUpgradeHandler: CreateV2UpgradeHandler,
	StoreUpgrades: store.StoreUpgrades{
		Added: []string{
			feesharetypes.ModuleName,
			globalfeetypes.ModuleName,
			packetforwardtypes.StoreKey,
			ibchookstypes.StoreKey,
			icqtypes.ModuleName,
		},
	},
}
