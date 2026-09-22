//go:build v64

package app

import (
	"github.com/terpnetwork/terp-core/v6/app/upgrades"
	v64 "github.com/terpnetwork/terp-core/v6/app/upgrades/v6_4"
)

// Upgrades registered on the v6.4.0 ELF. Do not register v6.3 here.
var Upgrades = []upgrades.Upgrade{
	v64.Upgrade,
}
