package v4

import (
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/module"
	upgradetypes "github.com/cosmos/cosmos-sdk/x/upgrade/types"

	"github.com/terpnetwork/terp-core/v2/app/keepers"
	clocktypes "github.com/terpnetwork/terp-core/v2/x/clock/types"
)

// CreateUpgradeHandler creates an SDK upgrade handler for v4
func CreateV4UpgradeHandler(
	mm *module.Manager,
	cfg module.Configurator,
	keepers *keepers.AppKeepers,
) upgradetypes.UpgradeHandler {
	return func(ctx sdk.Context, _ upgradetypes.Plan, vm module.VersionMap) (module.VersionMap, error) {

		// x/clock
		if err := keepers.ClockKeeper.SetParams(ctx, clocktypes.DefaultParams()); err != nil {
			return nil, err
		}
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
		ReturnFundsToCommunityPool(ctx, keepers.BankKeeper, keepers.DistrKeeper)

		// TODO: handle deployment & instantiation of headstash patch contract

		return vm, nil
	}
}
