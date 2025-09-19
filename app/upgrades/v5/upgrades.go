package v5

import (
	"context"
	"os"
	"path/filepath"

	upgradetypes "cosmossdk.io/x/upgrade/types"
	"github.com/CosmWasm/wasmd/x/wasm/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/module"
	wasmlctypes "github.com/cosmos/ibc-go/modules/light-clients/08-wasm/v10/types"
	"github.com/pelletier/go-toml/v2"
	"github.com/terpnetwork/terp-core/v4/app/keepers"
	"github.com/terpnetwork/terp-core/v4/app/upgrades"
)

// CreateUpgradeHandler creates an SDK upgrade handler for v5
func CreateV5UpgradeHandler(
	mm *module.Manager,
	configurator module.Configurator,
	bpm upgrades.BaseAppParamManager,
	keepers *keepers.AppKeepers,
	homepath string,
) upgradetypes.UpgradeHandler {
	return func(context context.Context, plan upgradetypes.Plan, vm module.VersionMap) (module.VersionMap, error) {
		ctx := sdk.UnwrapSDKContext(context)
		logger := ctx.Logger().With("upgrade", UpgradeName)

		// Run migrations first
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

		// ensure we are setting the wasm home path correctly
		err = MoveWasmDataPath(homepath)
		if err != nil {
			return nil, err
		}
		// decrease block times
		err = DecreaseBlockTimes(homepath)
		if err != nil {
			return nil, err
		}
		// enable permissionless uploads
		wasmParams := keepers.WasmKeeper.GetParams(ctx)
		wasmParams.CodeUploadAccess = types.AllowEverybody
		wasmParams.InstantiateDefaultPermission = types.AccessTypeEverybody
		err = keepers.WasmKeeper.SetParams(ctx, wasmParams)
		if err != nil {
			return nil, err
		}

		// enable wasm clients
		// set wasm client as an allowed client.
		// https://github.com/cosmos/ibc-go/blob/main/docs/docs/03-light-clients/04-wasm/03-integration.md
		params := keepers.IBCKeeper.ClientKeeper.GetParams(ctx)
		params.AllowedClients = append(params.AllowedClients, wasmlctypes.Wasm)
		keepers.IBCKeeper.ClientKeeper.SetParams(ctx, params)

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

func MoveWasmDataPath(homepath string) error {
	// define old and new paths
	oldPath := filepath.Join(homepath, "data", "wasm")
	newPath := filepath.Join(homepath, "wasm")

	// check if old path exists
	if _, err := os.Stat(oldPath); os.IsNotExist(err) {
		return nil // nothing to move
	}

	// ensure parent directory of new path exists
	if err := os.MkdirAll(filepath.Dir(newPath), 0o755); err != nil {
		return err
	}

	// move directory
	return os.Rename(oldPath, newPath)
}

func DecreaseBlockTimes(homepath string) error {
	// retrieve config.toml
	appConfigPath := filepath.Join(homepath, "config", "config.toml")
	configBytes, err := os.ReadFile(appConfigPath)
	if err != nil {
		return err
	}
	// unmarshal file
	var config map[string]interface{}
	if err := toml.Unmarshal(configBytes, &config); err != nil {
		return err
	}

	// update block speed to 2.4s
	if consensus, ok := config["consensus"].(map[string]interface{}); ok {
		consensus["timeout_commit"] = "2400ms"  // 2.4s
		consensus["timeout_propose"] = "2400ms" // 2.4s
	}
	// apply changes to config file
	updatedBytes, err := toml.Marshal(config)
	os.WriteFile(appConfigPath, updatedBytes, 0o644)
	return nil
}
