package v2

import (
	"fmt"

	packetforwardtypes "github.com/strangelove-ventures/packet-forward-middleware/v7/router/types"

	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/module"
	upgradetypes "github.com/cosmos/cosmos-sdk/x/upgrade/types"

	"github.com/terpnetwork/terp-core/v2/app"
	"github.com/terpnetwork/terp-core/v2/app/upgrades"
	feesharetypes "github.com/terpnetwork/terp-core/v2/x/feeshare/types"
	globalfeetypes "github.com/terpnetwork/terp-core/v2/x/globalfee/types"
)

func CreateV2UpgradeHandler(
	mm *module.Manager,
	cfg module.Configurator,
	keepers *app.TerpApp,
) upgradetypes.UpgradeHandler {
	return func(ctx sdk.Context, _ upgradetypes.Plan, vm module.VersionMap) (module.VersionMap, error) {
		// transfer module consensus version has been bumped to 2
		// the above is https://github.com/cosmos/ibc-go/blob/v5.1.0/docs/migrations/v3-to-v4.md
		logger := ctx.Logger().With("upgrade", UpgradeName)

		nativeFeeDenom := upgrades.GetChainsFeeDenomToken(ctx.ChainID())
		nativeBondDenom := upgrades.GetChainsBondDenomToken(ctx.ChainID())
		logger.Info(fmt.Sprintf("With native fee denom %s and native gas denom %s", nativeFeeDenom, nativeBondDenom))

		// Run migrations
		versionMap, err := mm.RunMigrations(ctx, cfg, vm)

		// New modules run AFTER the migrations, so to set the correct params after the default.

		// Packet Forward middleware initial params
		keepers.PacketForwardKeeper.SetParams(ctx, packetforwardtypes.DefaultParams())

		// GlobalFee
		minGasPrices := sdk.DecCoins{
			// 0.005uthiol
			sdk.NewDecCoinFromDec(nativeFeeDenom, sdk.NewDecWithPrec(25, 4)),
			// 0.0025uterp
			sdk.NewDecCoinFromDec(nativeBondDenom, sdk.NewDecWithPrec(25, 4)),
		}
		s, ok := keepers.ParamsKeeper.GetSubspace(globalfeetypes.ModuleName)
		if !ok {
			panic("global fee params subspace not found")
		}
		s.Set(ctx, globalfeetypes.ParamStoreKeyMinGasPrices, minGasPrices)
		logger.Info(fmt.Sprintf("upgraded global fee params to %s", minGasPrices))

		// FeeShare
		newFeeShareParams := feesharetypes.Params{
			EnableFeeShare:  true,
			DeveloperShares: sdk.NewDecWithPrec(50, 2), // = 50%
			AllowedDenoms:   []string{nativeFeeDenom, nativeBondDenom},
		}
		if err := keepers.FeeShareKeeper.SetParams(ctx, newFeeShareParams); err != nil {
			return nil, err
		}
		logger.Info("set feeshare params")

		return versionMap, err
	}
}
