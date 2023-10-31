package v4

import (
	"fmt"

	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/module"
	upgradetypes "github.com/cosmos/cosmos-sdk/x/upgrade/types"

	"github.com/terpnetwork/terp-core/v2/app/keepers"
	"github.com/terpnetwork/terp-core/v2/app/upgrades"
	clocktypes "github.com/terpnetwork/terp-core/v2/x/clock/types"
	globalfeetypes "github.com/terpnetwork/terp-core/v2/x/globalfee/types"
)

// CreateUpgradeHandler creates an SDK upgrade handler for v4
func CreateV4UpgradeHandler(
	mm *module.Manager,
	cfg module.Configurator,
	keepers *keepers.AppKeepers,
) upgradetypes.UpgradeHandler {
	return func(ctx sdk.Context, _ upgradetypes.Plan, vm module.VersionMap) (module.VersionMap, error) {
		logger := ctx.Logger().With("upgrade", UpgradeName)
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
		ReturnFundsToCommunityPool(ctx, keepers.DistrKeeper, keepers.BankKeeper)

		// TODO: handle deployment & instantiation of headstash patch contract

		return vm, nil
	}
}
