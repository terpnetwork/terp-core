package v4_1

import (
	"strconv"
	"strings"

	sdk "github.com/cosmos/cosmos-sdk/types"

	distrkeeper "github.com/cosmos/cosmos-sdk/x/distribution/keeper"
	"github.com/terpnetwork/terp-core/v4/app/upgrades"

	v3 "github.com/terpnetwork/terp-core/v4/app/upgrades/v3"
)

// revert headstash allocation by depositing funds back into community pool
func returnFundsToCommunityPool(
	ctx sdk.Context,
	dk distrkeeper.Keeper,
) {
	headstashes := v3.GetHeadstashPayments()
	total := int64(0)

	nativeDenom := upgrades.GetChainsDenomToken(ctx.ChainID())
	nativeFeeDenom := upgrades.GetChainsFeeDenomToken(ctx.ChainID())

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
		if err := dk.FundCommunityPool(ctx, terpcoins, addr); err != nil {
			panic(err)
		}
		if err := dk.FundCommunityPool(ctx, thiolcoins, addr); err != nil {
			panic(err)
		}
		total += amount
	}
}

// TODO: handle headstash-patch contract upload & instantiation
