package keeper

import (
	"github.com/terpnetwork/terp-core/x/terp/types"
)

var _ types.QueryServer = Keeper{}
