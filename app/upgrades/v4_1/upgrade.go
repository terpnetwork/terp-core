package v4_1

import (
	"context"
	"fmt"

	"cosmossdk.io/math"
	upgradetypes "cosmossdk.io/x/upgrade/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/module"

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
	bpm upgrades.BaseAppParamManager,
	keepers *keepers.AppKeepers,
) upgradetypes.UpgradeHandler {
	return func(ctx context.Context, _ upgradetypes.Plan, vm module.VersionMap) (module.VersionMap, error) {

		sdkCtx := sdk.UnwrapSDKContext(ctx)

		logger := sdkCtx.Logger().With("upgrade", UpgradeName)

		logger.Info(`
		:::     :::    :::           :::         ::::::::::   :::     :::::::::  ::::    ::: :::::::::: ::::::::  :::::::::: ::::    ::: :::::::::: 
		:+:     :+:   :+:          :+:+:         :+:        :+: :+:   :+:    :+: :+:+:   :+: :+:       :+:    :+: :+:        :+:+:   :+: :+:        
		+:+     +:+  +:+ +:+         +:+         +:+       +:+   +:+  +:+    +:+ :+:+:+  +:+ +:+       +:+        +:+        :+:+:+  +:+ +:+        
		+#+     +:+ +#+  +:+         +#+         :#::+::# +#++:++#++: +#++:++#:  +#+ +:+ +#+ +#++:++#  +#++:++#++ +#++:++#   +#+ +:+ +#+ +#++:++#   
		 +#+   +#+ +#+#+#+#+#+       +#+         +#+      +#+     +#+ +#+    +#+ +#+  +#+#+# +#+              +#+ +#+        +#+  +#+#+# +#+        
		  #+#+#+#        #+#   #+#   #+#         #+#      #+#     #+# #+#    #+# #+#   #+#+# #+#       #+#    #+# #+#        #+#   #+#+# #+#        
			###          ###   ### #######       ###      ###     ### ###    ### ###    #### ########## ########  ########## ###    #### ########## 

			
		`)
		// GlobalFee
		nativeFeeDenom := upgrades.GetChainsFeeDenomToken(sdkCtx.ChainID())
		minGasPrices := sdk.DecCoins{
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

		// x/clock
		if err := keepers.ClockKeeper.SetParams(sdkCtx, clocktypes.DefaultParams()); err != nil {
			return nil, err
		}
		// x/drip
		if err := keepers.DripKeeper.SetParams(sdkCtx, driptypes.DefaultParams()); err != nil {
			return nil, err
		}

		return vm, nil
	}
}
