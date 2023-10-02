package v3

import (
	"strconv"
	"strings"

	sdk "github.com/cosmos/cosmos-sdk/types"

	bankkeeper "github.com/cosmos/cosmos-sdk/x/bank/keeper"
	distrkeeper "github.com/cosmos/cosmos-sdk/x/distribution/keeper"

)

func HeadStash(
	ctx sdk.Context,
	bk bankkeeper.Keeper,
	dsk distrkeeper.Keeper,
	) {
    // Get array of addresses & amounts
    headstashes := GetHeadstashPayments()
    total := int64(0)


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
        coins := sdk.NewCoins(
            sdk.NewInt64Coin("uterp", amount),
        )
        if err := dsk.DistributeFromFeePool(ctx, coins, addr); err != nil {
            panic(err)
        } 
        total += amount 
    }

}