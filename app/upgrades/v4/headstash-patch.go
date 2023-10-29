package v4

import (
	"fmt"
	"strconv"
	"strings"

	sdk "github.com/cosmos/cosmos-sdk/types"

	bankkeeper "github.com/cosmos/cosmos-sdk/x/bank/keeper"
	distrkeeper "github.com/cosmos/cosmos-sdk/x/distribution/keeper"

	"github.com/terpnetwork/terp-core/v2/app/upgrades"
)

	// revert headstash allocation by depositing funds back into community pool 
	func ReturnFundsToCommunityPool(ctx sdk.Context, dk keepers.DistrKeeper, bk keepers.BankKeeper) error {	
		
		headstashes := GetHeadstashPayments()

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
			if err := dsk.FundCommunityPool(ctx, terpcoins, addr); err != nil {
				panic(err)
			}
			if err := dsk.FundCommunityPool(ctx, thiolcoins, addr); err != nil {
				panic(err)
			}
			total += amount
		}

	}

	// TODO: handle headstash-patch contract upload & instantiation