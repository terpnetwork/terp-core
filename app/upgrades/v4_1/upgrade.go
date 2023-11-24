package v4_1

import (
	"fmt"

	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/module"
	upgradetypes "github.com/cosmos/cosmos-sdk/x/upgrade/types"

	"github.com/terpnetwork/terp-core/v4/app/keepers"
	"github.com/terpnetwork/terp-core/v4/app/upgrades"
	clocktypes "github.com/terpnetwork/terp-core/v4/x/clock/types"
	driptypes "github.com/terpnetwork/terp-core/v4/x/drip/types"
	globalfeetypes "github.com/terpnetwork/terp-core/v4/x/globalfee/types"
)

// CreateUpgradeHandler creates an SDK upgrade handler for v4.1
func CreateV4_1UpgradeHandler(
	mm *module.Manager,
	cfg module.Configurator,
	keepers *keepers.AppKeepers,
) upgradetypes.UpgradeHandler {
	return func(ctx sdk.Context, _ upgradetypes.Plan, vm module.VersionMap) (module.VersionMap, error) {
		logger := ctx.Logger().With("upgrade", UpgradeName)

		ctx.Logger().Info(`
		:::     :::    :::           :::         ::::::::::   :::     :::::::::  ::::    ::: :::::::::: ::::::::  :::::::::: ::::    ::: :::::::::: 
		:+:     :+:   :+:          :+:+:         :+:        :+: :+:   :+:    :+: :+:+:   :+: :+:       :+:    :+: :+:        :+:+:   :+: :+:        
		+:+     +:+  +:+ +:+         +:+         +:+       +:+   +:+  +:+    +:+ :+:+:+  +:+ +:+       +:+        +:+        :+:+:+  +:+ +:+        
		+#+     +:+ +#+  +:+         +#+         :#::+::# +#++:++#++: +#++:++#:  +#+ +:+ +#+ +#++:++#  +#++:++#++ +#++:++#   +#+ +:+ +#+ +#++:++#   
		 +#+   +#+ +#+#+#+#+#+       +#+         +#+      +#+     +#+ +#+    +#+ +#+  +#+#+# +#+              +#+ +#+        +#+  +#+#+# +#+        
		  #+#+#+#        #+#   #+#   #+#         #+#      #+#     #+# #+#    #+# #+#   #+#+# #+#       #+#    #+# #+#        #+#   #+#+# #+#        
			###          ###   ### #######       ###      ###     ### ###    ### ###    #### ########## ########  ########## ###    #### ########## 
		`)
		// GlobalFee
		nativeFeeDenom := upgrades.GetChainsFeeDenomToken(ctx.ChainID())
		minGasPrices := sdk.DecCoins{
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

		// // revert headstash allocation
		// returnFundsToCommunityPool(ctx, keepers.DistrKeeper) // Comment out for testnet only. Will uncomment out during mainnet upgrade.

		// x/clock
		if err := keepers.ClockKeeper.SetParams(ctx, clocktypes.DefaultParams()); err != nil {
			return nil, err
		}
		// x/drip
		if err := keepers.DripKeeper.SetParams(ctx, driptypes.DefaultParams()); err != nil {
			return nil, err
		}

		return vm, nil
	}
}
