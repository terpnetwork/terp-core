package v2

import (
	"fmt"

	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/module"
	upgradetypes "github.com/cosmos/cosmos-sdk/x/upgrade/types"

	feesharetypes "github.com/terpnetwork/terp-core/v4/x/feeshare/types"

	globalfeetypes "github.com/terpnetwork/terp-core/v4/x/globalfee/types"

	tokenfactorytypes "github.com/terpnetwork/terp-core/v4/x/tokenfactory/types"

	icqtypes "github.com/cosmos/ibc-apps/modules/async-icq/v7/types"

	packetforwardtypes "github.com/cosmos/ibc-apps/middleware/packet-forward-middleware/v7/router/types"

	"github.com/terpnetwork/terp-core/v4/app/keepers"
	"github.com/terpnetwork/terp-core/v4/app/upgrades"
)

// We now charge 2 million gas * gas price to create a denom.
const NewDenomCreationGasConsume uint64 = 2_000_000

// CreateUpgradeHandler creates an SDK upgrade handler for v2
func CreateV2UpgradeHandler(
	mm *module.Manager,
	cfg module.Configurator,
	keepers *keepers.AppKeepers,
) upgradetypes.UpgradeHandler {
	return func(ctx sdk.Context, _ upgradetypes.Plan, vm module.VersionMap) (module.VersionMap, error) {
		logger := ctx.Logger().With("upgrade", UpgradeName)

		// Run migrations
		logger.Info(fmt.Sprintf("pre migrate version map: %v", vm))
		versionMap, err := mm.RunMigrations(ctx, cfg, vm)
		if err != nil {
			return nil, err
		}
		logger.Info(fmt.Sprintf("post migrate version map: %v", versionMap))

		nativeDenom := upgrades.GetChainsDenomToken(ctx.ChainID())
		logger.Info(fmt.Sprintf("With native denom %s", nativeDenom))

		// FeeShare
		newFeeShareParams := feesharetypes.Params{
			EnableFeeShare:  true,
			DeveloperShares: sdk.NewDecWithPrec(50, 2), // = 50%
			AllowedDenoms:   []string{nativeDenom},
		}
		if err := keepers.FeeShareKeeper.SetParams(ctx, newFeeShareParams); err != nil {
			return nil, err
		}
		logger.Info("set feeshare params")

		// GlobalFee
		minGasPrices := sdk.DecCoins{
			// 0.005uthiol
			sdk.NewDecCoinFromDec(nativeDenom, sdk.NewDecWithPrec(25, 4)),
		}
		newGlobalFeeParams := globalfeetypes.Params{
			MinimumGasPrices: minGasPrices,
		}
		if err := keepers.GlobalFeeKeeper.SetParams(ctx, newGlobalFeeParams); err != nil {
			return nil, err
		}
		logger.Info(fmt.Sprintf("upgraded global fee params to %s", minGasPrices))

		// x/TokenFactory
		// Use denom creation gas consumtion instead of fee for contract developers
		updatedTf := tokenfactorytypes.Params{
			DenomCreationFee:        nil,
			DenomCreationGasConsume: NewDenomCreationGasConsume,
		}

		if err := keepers.TokenFactoryKeeper.SetParams(ctx, updatedTf); err != nil {
			return nil, err
		}
		logger.Info(fmt.Sprintf("updated tokenfactory params to %v", updatedTf))

		// // Interchain Queries
		icqParams := icqtypes.NewParams(true, nil)
		keepers.ICQKeeper.SetParams(ctx, icqParams)

		// Packet Forward middleware initial params
		keepers.PacketForwardKeeper.SetParams(ctx, packetforwardtypes.DefaultParams())

		// Leave modules are as-is to avoid running InitGenesis.
		logger.Debug("running module migrations ...")
		return versionMap, err
	}
}
