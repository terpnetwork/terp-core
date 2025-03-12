package clock

import (
	"log"
	"time"

	storetypes "cosmossdk.io/store/types"
	"github.com/cosmos/cosmos-sdk/telemetry"
	sdk "github.com/cosmos/cosmos-sdk/types"

	"github.com/terpnetwork/terp-core/v4/x/clock/keeper"
	"github.com/terpnetwork/terp-core/v4/x/clock/types"
)

// EndBlocker executes on contracts at the end of the block.
func EndBlocker(ctx sdk.Context, k keeper.Keeper) {
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	defer telemetry.ModuleMeasureSince(types.ModuleName, time.Now(), telemetry.MetricKeyEndBlocker)

	message := []byte(types.EndBlockSudoMessage)
	p := k.GetParams(sdkCtx)

	errorExecs := make([]string, len(p.ContractAddresses))

	for idx, addr := range p.ContractAddresses {
		contract, err := sdk.AccAddressFromBech32(addr)
		if err != nil {
			errorExecs[idx] = addr
			continue
		}

		childCtx := sdkCtx.WithGasMeter(storetypes.NewGasMeter(p.ContractGasLimit))
		_, err = k.GetContractKeeper().Sudo(childCtx, contract, message)
		if err != nil {
			errorExecs[idx] = addr
			continue
		}
	}

	if len(errorExecs) > 0 {
		log.Printf("[x/clock] Execute Errors: %v", errorExecs)
	}
}
