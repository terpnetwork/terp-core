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
const NextUpgradeInfo = `{"binaries":{"linux/amd64":"https://s3.terp.network/releases/terp-core/v6.4.0/terpd-6.4.0-linux-amd64.tar.gz?checksum=sha256:3887809b2ba46ad7d7ef63bf276e83474232f300dfd2b4ac981cb36227eedbff","linux/arm64":"https://s3.terp.network/releases/terp-core/v6.4.0/terpd-6.4.0-linux-arm64.tar.gz?checksum=sha256:b5b819e003aacbd535bebd773cf7d67ee17eb525bf5aba43d5e6973daf988508"}}`

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
