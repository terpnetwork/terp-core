//go:build !v64 && !v63pre

package app

import (
	"github.com/terpnetwork/terp-core/v6/app/upgrades"
	v61 "github.com/terpnetwork/terp-core/v6/app/upgrades/v6_1"
	v62 "github.com/terpnetwork/terp-core/v6/app/upgrades/v6_2"
	v63 "github.com/terpnetwork/terp-core/v6/app/upgrades/v6_3"
)

// Upgrades registered on the v6.3.0 ELF. Plan v6.4 is not registered here;
// Cosmovisor swaps to the v6.4.0 ELF at the armed halt.
var Upgrades = []upgrades.Upgrade{
	v61.Upgrade,
	v62.Upgrade,
	v63.Upgrade,
}
