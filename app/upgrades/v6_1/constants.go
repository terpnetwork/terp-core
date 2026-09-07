package v6_1

import (
	store "github.com/cosmos/cosmos-sdk/store/v2/types"

	"github.com/terpnetwork/terp-core/v6/app/iavlhash"
	"github.com/terpnetwork/terp-core/v6/app/upgrades"
)

// UpgradeName is the on-chain plan name. Validators put this in the
// SoftwareUpgrade proposal. TSH: make tsh-upgrade-v61.
const UpgradeName = "v6.1"

// FoundationDAOAddr is the TerpNET Foundation DAO core (DAO DAO).
// Gov proposal 56 "Create TerpNET DAO" instantiate2 expect; confirmed
// on morocco-1 (code 23, self-admin). Circuit 50% maintenance share
// (params.circuit_dev_destination) is set here — not hardcoded in x/wasm.
const FoundationDAOAddr = "terp14w2qva6dx6wcsmq5fvplh7cr7nvptejznyvpe5hp5mtyqhxxjamsz3kw2w"

var Upgrade = upgrades.Upgrade{
	UpgradeName:          UpgradeName,
	CreateUpgradeHandler: CreateUpgradeHandler,
	StoreUpgrades: store.StoreUpgrades{
		Added: iavlhash.DestStores(),
		Deleted: []string{
			// x/params stays mounted for this upgrade so the handler can copy
			// leftover subspace values. Keys are wiped in the handler.
			// Unmount in feat/6.2.0-dev (plan v6.2), not this binary.
			"protocolpool",
		},
	},
}
