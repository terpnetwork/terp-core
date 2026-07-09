package v6

import (
	"context"

	upgradetypes "cosmossdk.io/x/upgrade/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/module"
	"github.com/terpnetwork/terp-core/v5/app/keepers"
	"github.com/terpnetwork/terp-core/v5/app/upgrades"
	tftypes "github.com/terpnetwork/terp-core/v5/x/tokenfactory/types"
)

func CreateV6UpgradeHandler(
	mm *module.Manager,
	configurator module.Configurator,
	_ upgrades.BaseAppParamManager,
	keepers *keepers.AppKeepers,
	_ string,
) upgradetypes.UpgradeHandler {
	return func(goCtx context.Context, plan upgradetypes.Plan, vm module.VersionMap) (module.VersionMap, error) {
		ctx := sdk.UnwrapSDKContext(goCtx)
		logger := ctx.Logger().With("upgrade", UpgradeName)

		// Run migrations (this initialises the hashmerchant module genesis).
		migrations, err := mm.RunMigrations(ctx, configurator, vm)
		if err != nil {
			return nil, err
		}

		// Set default tokenfactory params explicity
		keepers.TokenFactoryKeeper.SetParams(ctx, tftypes.DefaultParams())

		// patch broken delegations due to old bug in staking hooks, resyncing x/distr & x/staking data
		CustomV6PatchMethod(ctx, keepers, false)

		logger.Info("\n\n" +
			green + "                                                                                \n" +
			"  Camphene is a pine-fresh minor terpene found most concentrated in evergreen trees.    \n" +
			" 																		 				 \n" +
			" 																						 \n" +
			"  								░░░░                                                     \n" +
			"  								▒░░░░▒                                                   \n" +
			"  								░░░▒▓                                                    \n" +
			"  								░░░░                                                     \n" +
			"  								▒░░░█                                                    \n" +
			"  								░░░▒                                                     \n" +
			"  							█▓▓░▒▓                                                       \n" +
			"  						▓▓▓▒▒▒▓▓█                                                        \n" +
			"  						▓▓▒▒▒▒▒▒▒▓█                                                      \n" +
			"  			░░░▒   ▒░░▓▓▓▒▒▒░░░▒▒▓▓█                     ░░░                             \n" +
			"  			▒░░░░░░░░░░░▓▓▓▒▒▒▒▒▒▒▓██                    ░░░░░                           \n" +
			"  			▓░░░▒▓▓▓▓▓▓▓██▓▓▓▓▓▓▓▓██▓█                   ▒░░░                            \n" +
			"  			██          █████████▓▒▓█                  ░░░▒                              \n" +
			"  							█▓▒▓██▓▒▓█                 ▒░░                               \n" +
			"  							▓▓▒▓██▓▒▓▓              █▓▓▒█                                \n" +
			"  								█▓▒▓███▒▒▓██         █▓▓▒▒▒▓▓█                           \n" +
			"  								█▓▒▓▓▒▒▒▒▒▓▓█      █▓▒▒▒░▒▒▒▓                            \n" +
			"  								▓▓▒▒░░░▒▒▓▓▓▒▒▒v6.0.0▒▒▒▒▒░░░▒▒▓█                        \n" +
			"  								▓▓▒▒░░░▒▒▓▓▓▓██████▓▓▒▒▒▓▓▒▒▓▓▓           ▒░░░           \n" +
			"  								█▓▓▒▒▒▒▒▓▓█       ███▓▓▓███▓▓▒▒▒▓▓  ██▓▓▓▓░░░░░  ▒░░░    \n" +
			"  									██▓▓▓▓███        █▓▓█        █▓▓▒▓█▓▓▒▒▓█▒░░░░░░░░░░ \n" +
			"  									▓░▒█▓░▒       ███▓█            ██▓▓▒▒▓██▓▓▓▒░░▒▒▓▒▒  \n" +
			"  									▓▒░▓▓░░░░░░▓▓█▓▓▓▓▓▓█           ██▓▓▒▒░░▒▒▒▓         \n" +
			"  									▓░▒█ ▓▒▒▒░░▓▓▓▒▒░░▒▒▓█           ██▓▓▒▒▒▒▓▓█         \n" +
			"  								█▒▒▓         █▓▒▒░░▒▒▓▓░░░░░░       ██▓▓▓▓██             \n" +
			"  				░░░▒               ▓▒▒▓         ██▓▓▒▒▓▓██▓▒▒░░░       ▓▒▒▓              \n" +
			"  	▒▒           ░░▒▒▓           ███▒░▓             ▓▒██                ▓▒▒              \n" +
			"  	░░░░░▒▓       █▓▓▓█          █▓▓▓▒▓▓▓██        █▓▓                 █▒▒▓              \n" +
			"  	▒░░░▒░░░░▒▓█▓▓▓▒▓▓▓█        █▓▒▒▒▒▒▒▒▓██         █▒▓                 ▓▒▒▓            \n" +
			"  		▒░░░▒▓▒▒▒▒▒▒▓▓▓▓▓▒▒▒▒▒▓▓▒▒░░░▒▒▓██        █▓▓▓                █▒░▓               \n" +
			"  			█▓▒▒░░░▒▒▓▓▓▓▓▓▓███▓▒▒▓▓▓▒▓▓▓▒▓▓▓████▓▓▓▓▓██            ██▓▒▒▓               \n" +
			"  				▓▓▒▒▒▒▒▓▓█        █▓▓▓▓█▓▓█ █▓▓▓▓▓▓▓▒▒▒▒▒▓▓█         ██▓▓▒▒▓▓▓           \n" +
			"  				█▓▓▓▓▓██           █▓▓█         █▓▒▒░░░▒▒▒▒▒▒▒▓▓▓▓▓█▓▓▒▒▒▒▒▒▓▓           \n" +
			"  				▓▒▓▓            ███████        █▓▒▒▒▒▒▒▓▓▓▓▓▓▓▓▓▓▓█▓▓▒▒░░░▒▒▓█           \n" +
			"  				░░░░░▓█       █▓▓▓▓▓▓▓▓██   █▓▒░░░░░▓▓▓█          ██▓▒▒▒▓▒▒▓▓▒▒          \n" +
			"  				▒░░░░░░░░░░░░▓▓▓▓▒▒▒▒▒▒▓▓▓░░░░░░░░░░░█              ██▓▓▓▒▒▓█▒░░░░░▒     \n" +
			"  					░░░░░▓▒▒▒░░░░▒▒▒▒▒▒░░░▒▒▒▓▒░▒▒▓  ▓▒░░                   ▓▒░▒   ▓░░░  \n" +
			"  				▒░░░▒          █▓▒▒▒░░▒▒▒▓▓█     ▒▒░░▒    D-Camphene      ▓▒▒▓           \n" +
			"  			░░▒▓          █▓▓▒▒▒▒▒▒▓▓█      ░░░░░                   █▒░░░░               \n" +
			"  									█▓▓▓▓▓▓██        ▒░▒                    █▒░░░░       \n" +
			"  								█▒▒▓▓                                                    \n" +
			"  									░░░▒                                                 \n" +
			"  									░░░░                                                 \n" +
			"  									░░░░                                                 \n" +
			"  									░░░░                                                 \n" +
			"  								░░░░░█                                                   \n" +
			"  								░░░░░▓                                                   \n" +
			"  									▒░▒       v6 upgrade complete!                       \n" +
			"  																		                 \n" +
			" When combined with other phytochemicals, camphene packs a punch of medicinal benefits,  \n" +
			" against cardiovascular disease, fungal and viral infections, and apoptosis, or cell death in cancer cells.  \n" +
			"" + reset + "\n\n",
		)
		return migrations, nil
	}
}
