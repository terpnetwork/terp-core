package v6_3

import (
	store "github.com/cosmos/cosmos-sdk/store/v2/types"

	"github.com/terpnetwork/terp-core/v6/app/iavl"
	"github.com/terpnetwork/terp-core/v6/app/upgrades"
)

// UpgradeName is the on-chain plan name. Governance submits only this plan.
const UpgradeName = "v6.3"

// NextUpgradeName is armed by the v6.3 handler at apply height + NextUpgradeGap.
const NextUpgradeName = "v6.4"

const NextUpgradeGap int64 = 2

// NextUpgradeInfo is compact Cosmovisor binaries JSON (never file://).
// After linux recurate: scripts/release/stamp_v63_next_info.sh copies
// networks/upgrades/v6.4/cosmovisor.json so plan.info carries v6.4 checksums.
const NextUpgradeInfo = `{"binaries":{"linux/amd64":"https://s3.terp.network/releases/terp-core/v6.4.0/terpd-6.4.0-linux-amd64.tar.gz?checksum=sha256:6b49c432d7d8a8123d44ea8bcb5811a616e7e86b048bbe0c20b37dc0503a9ef4","linux/arm64":"https://s3.terp.network/releases/terp-core/v6.4.0/terpd-6.4.0-linux-arm64.tar.gz?checksum=sha256:98f9d9a92c9a72261fa062e16e42c5dfdb22e5172f972bb3cf1e0aaffca1171d"}}`

var Upgrade = upgrades.Upgrade{
	UpgradeName:          UpgradeName,
	CreateUpgradeHandler: CreateUpgradeHandler,
	StoreUpgrades: store.StoreUpgrades{
		Added: iavl.DestStores(),
	},
}
