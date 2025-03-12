package v2

import (
	"context"
	"fmt"

	"cosmossdk.io/math"
	upgradetypes "cosmossdk.io/x/upgrade/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/module"
	feesharetypes "github.com/terpnetwork/terp-core/v4/x/feeshare/types"

	globalfeetypes "github.com/terpnetwork/terp-core/v4/x/globalfee/types"

	tokenfactorytypes "github.com/terpnetwork/terp-core/v4/x/tokenfactory/types"

	icqtypes "github.com/cosmos/ibc-apps/modules/async-icq/v8/types"

	"github.com/terpnetwork/terp-core/v4/app/keepers"
	"github.com/terpnetwork/terp-core/v4/app/upgrades"
)

// We now charge 2 million gas * gas price to create a denom.
const NewDenomCreationGasConsume uint64 = 2_000_000

// CreateUpgradeHandler creates an SDK upgrade handler for v2
func CreateV2UpgradeHandler(
	mm *module.Manager,
	cfg module.Configurator,
	bpm upgrades.BaseAppParamManager,
	keepers *keepers.AppKeepers,
) upgradetypes.UpgradeHandler {
	return func(ctx context.Context, _ upgradetypes.Plan, vm module.VersionMap) (module.VersionMap, error) {
		sdkCtx := sdk.UnwrapSDKContext(ctx)
		logger := sdkCtx.Logger().With("upgrade", UpgradeName)

		// Run migrations
		logger.Info(fmt.Sprintf("pre migrate version map: %v", vm))
		versionMap, err := mm.RunMigrations(ctx, cfg, vm)
		if err != nil {
			return nil, err
		}
		logger.Info(fmt.Sprintf("post migrate version map: %v", versionMap))

		nativeDenom := upgrades.GetChainsDenomToken(sdkCtx.ChainID())
		logger.Info(fmt.Sprintf("With native denom %s", nativeDenom))

		// FeeShare
		newFeeShareParams := feesharetypes.Params{
			EnableFeeShare:  true,
			DeveloperShares: math.LegacyNewDecWithPrec(50, 2), // = 50%
			AllowedDenoms:   []string{nativeDenom},
		}
		if err := keepers.FeeShareKeeper.SetParams(sdkCtx, newFeeShareParams); err != nil {
			return nil, err
		}
		logger.Info("set feeshare params")

		// GlobalFee
		minGasPrices := sdk.DecCoins{
			// 0.005uthiol
			sdk.NewDecCoinFromDec(nativeDenom, math.LegacyNewDecWithPrec(25, 4)),
		}
		newGlobalFeeParams := globalfeetypes.Params{
			MinimumGasPrices: minGasPrices,
		}
		if err := keepers.GlobalFeeKeeper.SetParams(sdkCtx, newGlobalFeeParams); err != nil {
			return nil, err
		}
		logger.Info(fmt.Sprintf("upgraded global fee params to %s", minGasPrices))

		// x/TokenFactory
		// Use denom creation gas consumtion instead of fee for contract developers
		updatedTf := tokenfactorytypes.Params{
			DenomCreationFee:        nil,
			DenomCreationGasConsume: NewDenomCreationGasConsume,
		}

		keepers.TokenFactoryKeeper.SetParams(sdkCtx, updatedTf)
		logger.Info(fmt.Sprintf("updated tokenfactory params to %v", updatedTf))

		// // Interchain Queries
		icqParams := icqtypes.NewParams(true, nil)
		err = keepers.ICQKeeper.SetParams(sdkCtx, icqParams)
		if err != nil {
			return nil, err
		}
		// Packet Forward middleware initial params
		// if err := keepers.PacketForwardKeeper(sdkCtx, packetforwardtypes.DefaultParams()); err != nil {
		// 	return nil, err
		// }

		// Leave modules are as-is to avoid running InitGenesis.
		logger.Debug("running module migrations ...")
		return versionMap, err
	}
}
