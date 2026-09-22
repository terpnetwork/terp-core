//go:build v63pre

package app

import (
	"github.com/terpnetwork/terp-core/v6/app/upgrades"
	v61 "github.com/terpnetwork/terp-core/v6/app/upgrades/v6_1"
	v62 "github.com/terpnetwork/terp-core/v6/app/upgrades/v6_2"
)

// Upgrades on the local-genesis Cosmovisor genesis ELF (post-v6.2 shape).
var Upgrades = []upgrades.Upgrade{
	v61.Upgrade,
	v62.Upgrade,
}
