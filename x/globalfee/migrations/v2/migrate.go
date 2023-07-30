package v2

import (
	"fmt"

	"github.com/cosmos/cosmos-sdk/codec"
	sdk "github.com/cosmos/cosmos-sdk/types"

	"github.com/terpnetwork/terp-core/v2/x/globalfee/types"
)

const (
	ModuleName = "globalfee"
)

var ParamsKey = []byte{0x00}

// Migrate migrates the x/globalfee module state from the consensus version 1 to
// version 2. Specifically, it takes the parameters that are currently stored
// and managed by the x/params modules and stores them directly into the x/globalfee
// module state.
func Migrate(
	_ sdk.Context,
	store sdk.KVStore,
	cdc codec.BinaryCodec,
	bondDenom string,
) error {
	// https://api.terp.network/gaia/globalfee/v1beta1/minimum_gas_prices
	currParams := types.Params{
		MinimumGasPrices: sdk.DecCoins{
			// 0.075000000000000000 / uterpx
			sdk.NewDecCoinFromDec(bondDenom, sdk.NewDecWithPrec(75, 3)),
		},
	}

	fmt.Printf("migrating %s params: %+v\n", ModuleName, currParams)

	if err := currParams.Validate(); err != nil {
		return err
	}
	bz := cdc.MustMarshal(&currParams)
	store.Set(ParamsKey, bz)

	return nil
}
