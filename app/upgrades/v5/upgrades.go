package v5

import (
	"context"

	upgradetypes "cosmossdk.io/x/upgrade/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/module"
	"github.com/terpnetwork/terp-core/v4/app/keepers"
	"github.com/terpnetwork/terp-core/v4/app/upgrades"
)

// CreateUpgradeHandler creates an SDK upgrade handler for v5
func CreateV5UpgradeHandler(
	mm *module.Manager,
	configurator module.Configurator,
	bpm upgrades.BaseAppParamManager,
	keepers *keepers.AppKeepers,
) upgradetypes.UpgradeHandler {
	return func(context context.Context, plan upgradetypes.Plan, vm module.VersionMap) (module.VersionMap, error) {
		ctx := sdk.UnwrapSDKContext(context)
		logger := ctx.Logger().With("upgrade", UpgradeName)

		migrations, err := mm.RunMigrations(ctx, configurator, vm)
		if err != nil {
			return nil, err
		}

		// Update consensus params in order to safely enable comet pruning
		consensusParams, err := keepers.ConsensusParamsKeeper.ParamsStore.Get(ctx)
		if err != nil {
			return nil, err
		}

		// enable vote extensions
		consensusParams.Abci.VoteExtensionsEnableHeight = ctx.BlockHeight()
		err = keepers.ConsensusParamsKeeper.ParamsStore.Set(ctx, consensusParams)
		if err != nil {
			return nil, err
		}

		logger.Info(`
		
                  .!: ^7  7!^!^:J:.J:                                                               
                   7^^7Y  J^ :^:5~^5^^~.                                                            
                   ..  :  :!~!:.~  ~:^?^                                                            
                          ?DAB?     .::.                                                            
             .:.          !&&&!          .:.                                                        
         .:^~^:^~^:.      .B&B.      .:^~^:^~^:.                                                    
     .:^~^:.     .^~~^.    5@Y    .^~~^.  .. .:^~^:                                                 
  .^~~^.     ~!     .:^~^:.!&! :^~^:.    ~!7^    .^~^^.                                             
~~^:         :7         .:^!G!^:.        :!7:        :^~~.                                          
?   ::.       .             7. ^::^^              .~^   !^                                          
?  .~7^                     7  !!7:?              ~7?:  !^                                          
?  :7~.                     7  .::^:              :^^.  !^                      ^~~^ ~. :^          
?           Eudesmol        7           v5.0.0          !^                     !?  77J7^??          
?                     :.    7                           !^                     ^7^^7~?^ !7          
?  .~7:              ^?!.   7                      ^!^  !^                    ~: ::. .   .          
?  .^7^              :~!:.. 7                      :7.  !^          ^! !~   :!:                     
7^:...       .^      .:^^~^^7^:.         .^^       :. :^!~^::.      :7 ~! .~~.                      
 .^~^:.     :?J.  .^^~~~~^:. .:^~^:      !?7:     .:^~^.  ..:^^^^^:...  .:!:           .^^: :  ..   
    .:^~^:.  .~^^~~~~^:.         .^~~^.  .^^. .:^~^:.           ..:^^^^^77^::::::::::.:J^:~^Y^:Y^.:.
        .:^~^:^~~~^:                .:^~^:.:^~^:.                      .?^.......:.:^.:J:.~^Y^:Y^:!7
            .~7:.                       .:^^.                           :7      :?.:^7.:^^^.:  :.:~7
             .!                                                          !^      !.^7~            . 
             :!                                                          .7                         
             :!                                                           ~~                        
             :!                                                    ~! ^!^  ~.                       
      . ..   .!                                                    :! ^!! !!~!:^7..J.               
     ^?^?!.  .^. .   .                                              . .. .Y. ::~5~~P.^~:            
      !^~!^ !!^~^?~.~? .                                                  ^!~!::~  !.:7!            
        .   J~ :^J7^7J.^7:                                                           :^:            
            .~~!:^. .^.^7^    

		`)
		return migrations, nil
	}
}
