package v4

import (
	"fmt"

	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/module"
	upgradetypes "github.com/cosmos/cosmos-sdk/x/upgrade/types"

	"github.com/terpnetwork/terp-core/v4/app/keepers"
	"github.com/terpnetwork/terp-core/v4/app/upgrades"
	"github.com/terpnetwork/terp-core/v4/x/burn"
	globalfeetypes "github.com/terpnetwork/terp-core/v4/x/globalfee/types"
)

// CreateUpgradeHandler creates an SDK upgrade handler for v4
func CreateV4UpgradeHandler(
	mm *module.Manager,
	cfg module.Configurator,
	keepers *keepers.AppKeepers,
) upgradetypes.UpgradeHandler {
	return func(ctx sdk.Context, _ upgradetypes.Plan, vm module.VersionMap) (module.VersionMap, error) {
		logger := ctx.Logger().With("upgrade", UpgradeName)

		// GlobalFee
		nativeDenom := upgrades.GetChainsDenomToken(ctx.ChainID())
		nativeFeeDenom := upgrades.GetChainsFeeDenomToken(ctx.ChainID())
		minGasPrices := sdk.DecCoins{
			// 0.0025uterp
			sdk.NewDecCoinFromDec(nativeDenom, sdk.NewDecWithPrec(25, 4)),
			// 0.05uthiol
			sdk.NewDecCoinFromDec(nativeFeeDenom, sdk.NewDecWithPrec(5, 2)),
		}
		newGlobalFeeParams := globalfeetypes.Params{
			MinimumGasPrices: minGasPrices,
		}
		if err := keepers.GlobalFeeKeeper.SetParams(ctx, newGlobalFeeParams); err != nil {
			return nil, err
		}
		logger.Info(fmt.Sprintf("upgraded global fee params to %s", minGasPrices))

		// revert headstash allocation
		returnFundsToCommunityPool(ctx, keepers.DistrKeeper)

		// print the burn module address
		burnModule := keepers.AccountKeeper.GetModuleAddress(burn.ModuleName)
		logger.Info(fmt.Sprintf("burn module address %s", burnModule))

		// deployment & instantiation of headstash patch contract
		if err := setupHeadstashContract(ctx, keepers); err != nil {
			return nil, err
		}

		return vm, nil
	}
}
