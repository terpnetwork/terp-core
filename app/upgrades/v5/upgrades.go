package v5

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"cosmossdk.io/math"
	"github.com/pelletier/go-toml/v2"

	upgradetypes "cosmossdk.io/x/upgrade/types"
	cmtproto "github.com/cometbft/cometbft/proto/tendermint/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/module"
	"github.com/terpnetwork/terp-core/v5/app/keepers"
	"github.com/terpnetwork/terp-core/v5/app/upgrades"

	"github.com/CosmWasm/wasmd/x/wasm/types"
	wasmlctypes "github.com/cosmos/ibc-go/modules/light-clients/08-wasm/v10/types"
	icacontrollertypes "github.com/cosmos/ibc-go/v10/modules/apps/27-interchain-accounts/controller/types"
	icahosttypes "github.com/cosmos/ibc-go/v10/modules/apps/27-interchain-accounts/host/types"
	sca "github.com/terpnetwork/terp-core/v5/x/smart-account/types"
)

const (
	green  = "\033[32m"
	yellow = "\033[33m"
	red    = "\033[31m"
	reset  = "\033[0m"
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
		// set params
		icahostparam := icahosttypes.DefaultParams()
		icacontrollerparam := icacontrollertypes.DefaultParams()
		keepers.ICAHostKeeper.SetParams(ctx, icahostparam)
		keepers.ICAControllerKeeper.SetParams(ctx, icacontrollerparam)

		// Run migrations first
		migrations, err := mm.RunMigrations(ctx, configurator, vm)
		if err != nil {
			return nil, err
		}

		// Update consensus params in order to safely enable comet pruning
		consensusParams, err := keepers.ConsensusParamsKeeper.ParamsStore.Get(ctx)
		consensusParams = cmtproto.ConsensusParams{
			Block:     consensusParams.Block,
			Evidence:  consensusParams.Evidence,
			Validator: consensusParams.Validator,
			Version:   consensusParams.Version,
			Abci: &cmtproto.ABCIParams{
				VoteExtensionsEnableHeight: ctx.BlockHeight() + 1,
			},
		}
		if err != nil {
			return nil, err
		}
		fmt.Printf("consensusParams: %v\n", consensusParams)
		// retain signed blocks duration given new block speeds
		p, _ := keepers.SlashingKeeper.GetParams(ctx)
		p.SignedBlocksWindow = 25_000 /// ~16.67 hours
		keepers.SlashingKeeper.SetParams(ctx, p)

		consensusParams.Evidence.MaxAgeNumBlocks = 756_000
		consensusParams.Evidence.MaxAgeDuration = time.Second * 1_814_400 // 21 days (in seconds)
		// enable vote extensions
		consensusParams.Abci.VoteExtensionsEnableHeight = ctx.BlockHeight() + 1
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

		// update mint keepers blocks_per_year to reflect new block speed
		mp, err := keepers.MintKeeper.Params.Get(ctx)
		if err != nil {
			return nil, err
		}
		mp.BlocksPerYear = 13148719 // @ 31556925 seconds per tropical year (365 days, 5 hours, 48 mins, 45 seconds)
		keepers.MintKeeper.Params.Set(ctx, mp)

		// enable wasm clients
		// set wasm client as an allowed client.
		// https://github.com/cosmos/ibc-go/blob/main/docs/docs/03-light-clients/04-wasm/03-integration.md
		params := keepers.IBCKeeper.ClientKeeper.GetParams(ctx)
		params.AllowedClients = append(params.AllowedClients, wasmlctypes.Wasm)
		keepers.IBCKeeper.ClientKeeper.SetParams(ctx, params)

		// configure expidited proposals
		govparams, _ := keepers.GovKeeper.Params.Get(ctx)
		govparams.ExpeditedMinDeposit = sdk.NewCoins(sdk.NewCoin("uterp", math.NewInt(10_000_000_000))) // 10K
		newExpeditedVotingPeriod := time.Minute * 60 * 24                                               // 1 DAY
		govparams.ExpeditedVotingPeriod = &newExpeditedVotingPeriod
		govparams.ExpeditedThreshold = "0.75" // 75% voting threshold
		keepers.GovKeeper.Params.Set(ctx, govparams)

		// Set the x/smart-account authenticator params in the store
		authenticatorParams := sca.DefaultParams()
		// authenticatorParams.CircuitBreakerControllers = append(authenticatorParams.CircuitBreakerControllers, CircuitBreakerController)
		keepers.SmartAccountKeeper.SetParams(ctx, authenticatorParams)

		logger.Info("\n\n" +
			green + "                  .!: ^7  7!^!^:J:.J:                                                            \n" +
			"                   7^^7Y  J^ :^:5~^5^^~.                                                          \n" +
			"                   ..  :  :!~!:.~  ~:^?^                                                            \n" +
			"                          ?DAB?     .::.                                                            \n" +
			"             .:.          !&&&!          .:.                                                        \n" +
			"         .:^~^:^~^:.      .B&B.      .:^~^:^~^:.                                                    \n" +
			"     .:^~^:.     .^~~^.    5@Y    .^~~^.  .. .:^~^:                                                 \n" +
			"  .^~~^.     ~!     .:^~^:.!&! :^~^:.    ~!7^    .^~^^.                                             \n" +
			"~~^:         :7         .:^!G!^:.        :!7:        :^~~.                                       \n" +
			"?   ::.       .             7. ^::^^              .~^   !^                                       \n" +
			"?  .~7^                     7  !!7:?              ~7?:  !^                                       \n" +
			"?  :7~.                     7  .::^:              :^^.  !^                      ^~~^ ~. :^       \n" +
			"?           " + red + "Eudesmol" + green + "        7           " + yellow + "v5.0.0" + green + "          !^                     !?  77J7^??       \n" +
			"?                     :.    7                           !^                     ^7^^7~?^ !7       \n" +
			"?  .~7:              ^?!.   7                      ^!^  !^                    ~: ::. .   .       \n" +
			"?  .^7^              :~!:.. 7                      :7.  !^          ^! !~   :!:                  \n" +
			"7^:...       .^      .:^^~^^7^:.         .^^       :. :^!~^::.      :7 ~! .~~.                    \n" +
			" .^~^:.     :?J.  .^^~~~~^:. .:^~^:      !?7:     .:^~^.  ..:^^^^^:...  .:!:           .^^: :  .. \n" +
			"    .:^~^:.  .~^^~~~~^:.         .^~~^.  .^^. .:^~^:.           ..:^^^^^77^::::::::::.:J^:~^Y^:Y^.:.\n" +
			"        .:^~^:^~~~^:                .:^~^:.:^~^:.                      .?^.......:.:^.:J:.~^Y^:Y^:!7\n" +
			"            .~7:.                       .:^^.                           :7      :?.:^7.:^^^.:  :.:~7\n" +
			"             .!                                                          !^      !.^7~            . \n" +
			"             :!                                                          .7                         \n" +
			"             :!                                                           ~~                        \n" +
			"             :!                                                    ~! ^!^  ~.                       \n" +
			"      . ..   .!                                                    :! ^!! !!~!:^7..J.               \n" +
			"     ^?^?!.  .^. .   .                                              . .. .Y. ::~5~~P.^~:            \n" +
			"      !^~!^ !!^~^?~.~? .                                                  ^!~!::~  !.:7!            \n" +
			"        .   J~ :^J7^7J.^7:                                                           :^:            \n" +
			"            .~~!:^. .^.^7^    " + reset + "\n\n",
		)
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
