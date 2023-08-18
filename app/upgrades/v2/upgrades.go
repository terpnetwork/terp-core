package v2

import (
	"fmt"

	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/module"
	upgradetypes "github.com/cosmos/cosmos-sdk/x/upgrade/types"
	ibcfeetypes "github.com/cosmos/ibc-go/v7/modules/apps/29-fee/types"
	icqtypes "github.com/strangelove-ventures/async-icq/v7/types"
	packetforwardtypes "github.com/strangelove-ventures/packet-forward-middleware/v7/router/types"
	"github.com/terpnetwork/terp-core/v2/app/keepers"
	"github.com/terpnetwork/terp-core/v2/app/upgrades"
	feesharetypes "github.com/terpnetwork/terp-core/v2/x/feeshare/types"
	globalfeetypes "github.com/terpnetwork/terp-core/v2/x/globalfee/types"
)

func CreateUpgradeHandler(
	mm *module.Manager,
	configurator module.Configurator,
	bpm upgrades.BaseAppParamManager,
	keepers *keepers.AppKeepers,
) upgradetypes.UpgradeHandler {
	return func(ctx sdk.Context, plan upgradetypes.Plan, fromVM module.VersionMap) (module.VersionMap, error) { // the above is https://github.com/cosmos/ibc-go/blob/v5.1.0/docs/migrations/v3-to-v4.md
		logger := ctx.Logger().With("upgrade", UpgradeName)

		nativeFeeDenom := "uterp"
		nativeBondDenom := "uterp"
		ctx.Logger().Info(`
	 

                           ▄░ ▄

                            ▓▓▀                                      ░░▐

                            ▒▒                                      ▐▒▀▀

                            ▓▓                                     ▐░▀

             ▐▒▒▒         ▄▓▒▀▄                    ▒░▒            ▄▓▀               ▒░▐

              ▒▒   ░░▒▄▒▓▓▓▓▓▓▓▓▄▄                ▓▓▒▀▄▄▄▄▄▄▄▄▄▄▓▒▒▓                ▒░

              ▒▒   ▀▀▀     ▓▒▀    ▀▀▒▒▒         ▄▒▓▓▓▓▓▀▀▀▀▀▀▀▀▀░▐▓▓                ▒▐

             ▄▓▓▄          ▓▓          ▄▄▄ ▄▄▒▒▓▀             ▓▒▒  ▓▓▄              ▒▓

          ▄▄▓▓▓▓▓▌▄▄▄      ▓▓      ▄▄▄▓▓▒▒▓▀▀                        ▓▓▄          ▄▓▒▀▄

     ▒▒▓▀▀▀  ▀▓▓▀ ▀▀▀▀▓▓▓▓▓▒▒▓▓▓▓▓▀▀▀▀▐▒ ▐▀                           ▀▓▓      ▄▄▓▓▓▓▓▓▄▄

              ▒░          ▓▓▓▀         ▓▒▀                              ▓▒▒▒▓▓▓▓▓▓▀ ▀  ▀▀▒▄░▄

             ▐░▄▒          ▓▓                                           ▓▓▓▓▓  ▀▀▀          ▓▄▒

               ▀           ▓▓                                           ▓▓▓

                           ▓▓                                           ▒▒▌

                           ▓▓                                          ▓▓▒

                           ▓▓                                          ▒▒▌

                         ▐▓▒▒▓▄                                      ▄▓▓▓

                   ▐░▐▒▒▓▓▓▓▓▓▓▒▄▄           ▒░▄░                   ▐▓▓▓▓▌

                    ▀▀   ░░     ▀▀▓▓▒▄▄    ▄▒▄                  ▒░▄▒▀▀▓██

                       ▒▄▄▒          ▀▀▓▓▒▒▒▓                          ▐█▌

                                        ▀▓▓▓▓▄                          ▓▓▄

                                           ▀▒▓▒                  ▐░ ▄    █▓▄      ░▄▄▒
´
                                             ▀▒▒▄                ▐░░    ▐▓▒▒▓▓▀▀▀

                                              ▐▓▒▒▀▄           ▄▄▒▓▄▄▓▓▓▀▀▓▒▓

                                               ▓▓▓▓▓▀▀▀▀▓▓▓▓▓▓▓▓▒▓▓▓▀      ▒░

                                                ▒▓              ▀██        ▐

                                             ▐░▄▒▌               ▀▓        ▒▄▄▒

                                              ▓▓▒                 ▒▒

                                             ▓▓█▒▓                ▒░░

                                           ▒▓▓▓▓▓▓░               ▀▀▀

                                     ▄  ▒▄▀       ▀▒

                                     ▀▒▓             ▒░░▒

                                                      ▀▀▀                                                                                                                                      
   HHHHHHHHH     HHHHHHHHH                                                            lllllll                                                           
   H:::::::H     H:::::::H                                                            l:::::l                                                           
   H:::::::H     H:::::::H                                                            l:::::l                                                           
   HH::::::H     H::::::HH                                                            l:::::l                                                           
	 H:::::H     H:::::H  uuuuuu    uuuuuu     mmmmmmm    mmmmmmm   uuuuuu    uuuuuu   l::::l     eeeeeeeeeeee    nnnn  nnnnnnnn        eeeeeeeeeeee    
	 H:::::H     H:::::H  u::::u    u::::u   mm:::::::m  m:::::::mm u::::u    u::::u   l::::l   ee::::::::::::ee  n:::nn::::::::nn    ee::::::::::::ee  
	 H::::::HHHHH::::::H  u::::u    u::::u  m::::::::::mm::::::::::mu::::u    u::::u   l::::l  e::::::eeeee:::::een::::::::::::::nn  e::::::eeeee:::::ee
	 H:::::::::::::::::H  u::::u    u::::u  m::::::::::::::::::::::mu::::u    u::::u   l::::l e::::::e     e:::::enn:::::::::::::::ne::::::e     e:::::e
	 H:::::::::::::::::H  u::::u    u::::u  m:::::mmm::::::mmm:::::mu::::u    u::::u   l::::l e:::::::eeeee::::::e  n:::::nnnn:::::ne:::::::eeeee::::::e
	 H::::::HHHHH::::::H  u::::u    u::::u  m::::m   m::::m   m::::mu::::u    u::::u   l::::l e:::::::::::::::::e   n::::n    n::::ne:::::::::::::::::e 
	 H:::::H     H:::::H  u::::u    u::::u  m::::m   m::::m   m::::mu::::u    u::::u   l::::l e::::::eeeeeeeeeee    n::::n    n::::ne::::::eeeeeeeeeee  
	 H:::::H     H:::::H  u:::::uuuu:::::u  m::::m   m::::m   m::::mu:::::uuuu:::::u   l::::l e:::::::e             n::::n    n::::ne:::::::e           
   HH::::::H     H::::::HHu:::::::::::::::uum::::m   m::::m   m::::mu:::::::::::::::uul::::::le::::::::e            n::::n    n::::ne::::::::e          
   H:::::::H     H:::::::H u:::::::::::::::um::::m   m::::m   m::::m u:::::::::::::::ul::::::l e::::::::eeeeeeee    n::::n    n::::n e::::::::eeeeeeee  
   H:::::::H     H:::::::H  uu::::::::uu:::um::::m   m::::m   m::::m  uu::::::::uu:::ul::::::l  ee:::::::::::::e    n::::n    n::::n  ee:::::::::::::e  
   HHHHHHHHH     HHHHHHHHH    uuuuuuuu  uuuummmmmm   mmmmmm   mmmmmm    uuuuuuuu  uuuullllllll    eeeeeeeeeeeeee    nnnnnn    nnnnnn    eeeeeeeeeeeeee  
`)

		logger.Info(fmt.Sprintf("With native fee denom %s and native gas denom %s", nativeFeeDenom, nativeBondDenom))

		// Run migrations
		logger.Info(fmt.Sprintf("pre migrate version map: %v", fromVM))

		versionMap, err := mm.RunMigrations(ctx, configurator, fromVM)
		if err != nil {
			return nil, err
		}

		logger.Info(fmt.Sprintf("post migrate version map: %v", versionMap))

		// IBCFee
		// vm[ibcfeetypes.ModuleName] = mm.Modules[ibcfeetypes.ModuleName].ConsensusVersion()
		logger.Info(fmt.Sprintf("ibcfee module version %s set", fmt.Sprint(fromVM[ibcfeetypes.ModuleName])))

		// Packet Forward middleware initial params
		keepers.PacketForwardKeeper.SetParams(ctx, packetforwardtypes.DefaultParams())

		// x/global-fee
		if err := keepers.GlobalFeeKeeper.SetParams(ctx, globalfeetypes.DefaultParams()); err != nil {
			return nil, err
		}

		minGasPrices := sdk.DecCoins{
			// 0.005uthiol
			sdk.NewDecCoinFromDec(nativeFeeDenom, sdk.NewDecWithPrec(25, 4)),
		}
		newGlobalFeeParams := globalfeetypes.Params{
			MinimumGasPrices: minGasPrices,
		}
		if err := keepers.GlobalFeeKeeper.SetParams(ctx, newGlobalFeeParams); err != nil {
			return nil, err
		}
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

		// Interchain Queries
		icqParams := icqtypes.NewParams(true, nil)
		keepers.ICQKeeper.SetParams(ctx, icqParams)

		return mm.RunMigrations(ctx, configurator, fromVM)
	}
}
