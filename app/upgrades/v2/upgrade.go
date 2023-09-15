package v2

import (
	"fmt"

	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/module"
	upgradetypes "github.com/cosmos/cosmos-sdk/x/upgrade/types"

	feesharekeeper "github.com/terpnetwork/terp-core/x/feeshare/keeper"
	feesharetypes "github.com/terpnetwork/terp-core/x/feeshare/types"

	globalfeekeeper "github.com/terpnetwork/terp-core/x/globalfee/keeper"
	globalfeetypes "github.com/terpnetwork/terp-core/x/globalfee/types"

	tokenfactorykeeper "github.com/terpnetwork/terp-core/x/tokenfactory/keeper"
	tokenfactorytypes "github.com/terpnetwork/terp-core/x/tokenfactory/types"

	icqkeeper "github.com/cosmos/ibc-apps/modules/async-icq/v7/keeper"
	icqtypes "github.com/cosmos/ibc-apps/modules/async-icq/v7/types"

	packetforwardkeeper "github.com/cosmos/ibc-apps/middleware/packet-forward-middleware/v7/router/keeper"
	packetforwardtypes "github.com/cosmos/ibc-apps/middleware/packet-forward-middleware/v7/router/types"

	"github.com/terpnetwork/terp-core/app/upgrades"
)

// We now charge 2 million gas * gas price to create a denom.
const NewDenomCreationGasConsume uint64 = 2_000_000

// CreateUpgradeHandler creates an SDK upgrade handler for v2
func CreateUpgradeHandler(
	mm *module.Manager,
	configurator module.Configurator,
	fsk feesharekeeper.Keeper,
	gfk globalfeekeeper.Keeper,
	tfk tokenfactorykeeper.Keeper,
	icqk icqkeeper.Keeper,
	pfk packetforwardkeeper.Keeper,
) upgradetypes.UpgradeHandler {
	return func(ctx sdk.Context, _ upgradetypes.Plan, vm module.VersionMap) (module.VersionMap, error) {
		logger := ctx.Logger().With("upgrade", UpgradeName)

		nativeDenom := upgrades.GetChainsDenomToken(ctx.ChainID())
		logger.Info(fmt.Sprintf("With native denom %s", nativeDenom))

		// FeeShare
		newFeeShareParams := feesharetypes.Params{
			EnableFeeShare:  true,
			DeveloperShares: sdk.NewDecWithPrec(50, 2), // = 50%
			AllowedDenoms:   []string{nativeDenom},
		}
		if err := fsk.SetParams(ctx, newFeeShareParams); err != nil {
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
		if err := gfk.SetParams(ctx, newGlobalFeeParams); err != nil {
			return nil, err
		}
		logger.Info(fmt.Sprintf("upgraded global fee params to %s", minGasPrices))

		// x/TokenFactory
		// Use denom creation gas consumtion instead of fee for contract developers
		updatedTf := tokenfactorytypes.Params{
			DenomCreationFee:        nil,
			DenomCreationGasConsume: NewDenomCreationGasConsume,
		}

		if err := tfk.SetParams(ctx, updatedTf); err != nil {
			return nil, err
		}
		logger.Info(fmt.Sprintf("updated tokenfactory params to %v", updatedTf))

		// // Interchain Queries
		icqParams := icqtypes.NewParams(true, nil)
		icqk.SetParams(ctx, icqParams)

		// Packet Forward middleware initial params
		pfk.SetParams(ctx, packetforwardtypes.DefaultParams())

		// Leave modules are as-is to avoid running InitGenesis.
		logger.Debug("running module migrations ...")
		return mm.RunMigrations(ctx, configurator, vm)
	}
}
