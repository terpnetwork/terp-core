package v6_2

import (
	store "github.com/cosmos/cosmos-sdk/store/v2/types"

	"github.com/terpnetwork/terp-core/v6/app/upgrades"
)

// UpgradeName is the on-chain plan name. Must not be registered on
// feat/6.1.0-dev — that binary's StoreUpgrades already Added b3-*.
const UpgradeName = "v6.2"

var Upgrade = upgrades.Upgrade{
	UpgradeName:          UpgradeName,
	CreateUpgradeHandler: CreateUpgradeHandler,
	// Do not Renamed b3-* onto bank/staking/acc: IAVL rejects initialVersion
	// on a name that already has history (TSH: "initial version set to H,
	// but found earlier version"). Do not mount b3-* (GenerateKeys dropped
	// them). The first v6.2 commit then omits those names from CommitInfo,
	// so the live trees are keeper names only. IBC is untouched.
	StoreUpgrades: store.StoreUpgrades{},
}
