package v3

import (
	"fmt"
	"strconv"
	"strings"

	sdk "github.com/cosmos/cosmos-sdk/types"

	bankkeeper "github.com/cosmos/cosmos-sdk/x/bank/keeper"
	distrkeeper "github.com/cosmos/cosmos-sdk/x/distribution/keeper"

	"github.com/terpnetwork/terp-core/v2/app/upgrades"
)

func HeadStash(
	ctx sdk.Context,
	bk bankkeeper.Keeper,
	dsk distrkeeper.Keeper,
) {
	// Get array of addresses & amounts
	logger := ctx.Logger().With("upgrade", UpgradeName)
	headstashes := GetHeadstashPayments()
	total := int64(0)

	nativeDenom := upgrades.GetChainsDenomToken(ctx.ChainID())
	nativeFeeDenom := upgrades.GetChainsFeeDenomToken(ctx.ChainID())

	logger.Info(fmt.Sprintf("With native denom %s", nativeDenom))
	logger.Info(fmt.Sprintf("With native fee denom %s", nativeFeeDenom))

	for _, headstash := range headstashes {
		addr, err := sdk.AccAddressFromBech32(headstash[0])
		if err != nil {
			panic(err)
		}
		// defines the value associated with a given address
		amount, err := strconv.ParseInt(strings.TrimSpace(headstash[1]), 10, 64)
		if err != nil {
			panic(err)
		}
		terpcoins := sdk.NewCoins(
			sdk.NewInt64Coin(nativeDenom, amount),
		)
		thiolcoins := sdk.NewCoins(
			sdk.NewInt64Coin(nativeFeeDenom, amount),
		)
		if err := dsk.DistributeFromFeePool(ctx, terpcoins, addr); err != nil {
			panic(err)
		}
		if err := dsk.DistributeFromFeePool(ctx, thiolcoins, addr); err != nil {
			panic(err)
		}
		total += amount
	}
}
