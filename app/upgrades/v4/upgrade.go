package v4

import (
	"context"
	"fmt"

	"cosmossdk.io/math"
	upgradetypes "cosmossdk.io/x/upgrade/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/module"
	"github.com/terpnetwork/terp-core/v4/app/keepers"
	"github.com/terpnetwork/terp-core/v4/app/upgrades"
	globalfeetypes "github.com/terpnetwork/terp-core/v4/x/globalfee/types"
)

// CreateUpgradeHandler creates an SDK upgrade handler for v4
func CreateV4UpgradeHandler(
	mm *module.Manager,
	cfg module.Configurator,
	bpm upgrades.BaseAppParamManager,
	keepers *keepers.AppKeepers,
) upgradetypes.UpgradeHandler {
	return func(ctx context.Context, _ upgradetypes.Plan, vm module.VersionMap) (module.VersionMap, error) {
		sdkCtx := sdk.UnwrapSDKContext(ctx)
		logger := sdkCtx.Logger().With("upgrade", UpgradeName)

		// GlobalFee
		nativeDenom := upgrades.GetChainsDenomToken(sdkCtx.ChainID())
		nativeFeeDenom := upgrades.GetChainsFeeDenomToken(sdkCtx.ChainID())
		minGasPrices := sdk.DecCoins{
			// 0.0025uterp
			sdk.NewDecCoinFromDec(nativeDenom, math.LegacyNewDecWithPrec(25, 4)),
			// 0.05uthiol
			sdk.NewDecCoinFromDec(nativeFeeDenom, math.LegacyNewDecWithPrec(5, 2)),
		}
		newGlobalFeeParams := globalfeetypes.Params{
			MinimumGasPrices: minGasPrices,
		}
		if err := keepers.GlobalFeeKeeper.SetParams(sdkCtx, newGlobalFeeParams); err != nil {
			return nil, err
		}
		logger.Info(fmt.Sprintf("upgraded global fee params to %s", minGasPrices))

		// revert headstash allocation
		returnFundsToCommunityPool(sdkCtx, keepers.DistrKeeper)

		// archived & removed burn module [#155](https://github.com/terpnetwork/terp-core/issues/155), reverted to [default denom burning function](https://pkg.go.dev/github.com/CosmWasm/wasmd@v0.43.0/x/wasm/types#Burner.BurnCoins)
		// print the burn module address
		// burnModule := keepers.AccountKeeper.GetModuleAddress(burn.ModuleName)
		// logger.Info(fmt.Sprintf("burn module address %s", burnModule))

		// deployment & instantiation of headstash patch contract
		// if err := setupHeadstashContract(ctx, keepers); err != nil {
		// 	return nil, err
		// }

		return vm, nil
	}
}
