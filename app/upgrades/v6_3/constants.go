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
const NextUpgradeInfo = `{"binaries":{"linux/amd64":"https://s3.terp.network/releases/terp-core/v6.4.0/terpd-6.4.0-linux-amd64.tar.gz?checksum=sha256:26fba3599abbc32c5279f7f284310266f49a544fa127534c0e78881d4dca3a37","linux/arm64":"https://s3.terp.network/releases/terp-core/v6.4.0/terpd-6.4.0-linux-arm64.tar.gz?checksum=sha256:206da549117c4cb479d8ed9c2116d6acbd8e2df10a7bf735986ab7104557eaff","darwin/arm64":"https://s3.terp.network/releases/terp-core/v6.4.0/terpd-6.4.0-darwin-arm64.tar.gz?checksum=sha256:1def360c91cd7ca1ce979b2d78ff40616b9ef76f9688e14c1409f16fdc2deca9"}}`

var Upgrade = upgrades.Upgrade{
	UpgradeName:          UpgradeName,
	CreateUpgradeHandler: CreateUpgradeHandler,
	// Deleted runs in the SDK store loader, before CreateUpgradeHandler copies
	// dest stores. ibccallbacks is added by RunMigrations at the start of that
	// handler. Callbacks has no store of its own.
	StoreUpgrades: store.StoreUpgrades{
		Added:   iavl.DestStores(),
		Deleted: []string{"hooks-for-ibc"},
	},
}
