package cmd

import (
	"errors"
	"io"
	"os"
	"path/filepath"

	"github.com/CosmWasm/wasmd/x/wasm"
	wasmcli "github.com/CosmWasm/wasmd/x/wasm/client/cli"
	wasmkeeper "github.com/CosmWasm/wasmd/x/wasm/keeper"
	wasmtypes "github.com/CosmWasm/wasmd/x/wasm/types"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/spf13/cast"
	"github.com/spf13/cobra"
	"github.com/spf13/viper"

	"cosmossdk.io/client/v2/autocli"
	"cosmossdk.io/core/appmodule"
	"cosmossdk.io/log"
	cosmosdb "github.com/cosmos/cosmos-db"
	runtimeservices "github.com/cosmos/cosmos-sdk/runtime/services"
	authcodec "github.com/cosmos/cosmos-sdk/x/auth/codec"

	tmcfg "github.com/cometbft/cometbft/config"
	"github.com/cometbft/cometbft/crypto"
	"github.com/cometbft/cometbft/libs/bytes"
	tmcli "github.com/cometbft/cometbft/libs/cli"

	simtestutil "github.com/cosmos/cosmos-sdk/testutil/sims"
	"github.com/cosmos/cosmos-sdk/types/module"

	"github.com/cosmos/cosmos-sdk/client"
	"github.com/cosmos/cosmos-sdk/client/config"
	"github.com/cosmos/cosmos-sdk/client/flags"
	"github.com/cosmos/cosmos-sdk/client/keys"
	"github.com/cosmos/cosmos-sdk/client/pruning"
	"github.com/cosmos/cosmos-sdk/client/rpc"
	"github.com/cosmos/cosmos-sdk/server"
	serverconfig "github.com/cosmos/cosmos-sdk/server/config"
	servertypes "github.com/cosmos/cosmos-sdk/server/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/version"
	authcmd "github.com/cosmos/cosmos-sdk/x/auth/client/cli"
	authtypes "github.com/cosmos/cosmos-sdk/x/auth/types"
	"github.com/cosmos/cosmos-sdk/x/crisis"
	genutilcli "github.com/cosmos/cosmos-sdk/x/genutil/client/cli"

	"github.com/terpnetwork/terp-core/v5/app"
	"github.com/terpnetwork/terp-core/v5/app/params"
)

// NewRootCmd creates a new root command for terpd. It is called once in the
// main function.
func NewRootCmd() (*cobra.Command, params.EncodingConfig) {
	encodingConfig := app.MakeEncodingConfig()

	cfg := sdk.GetConfig()
	cfg.SetBech32PrefixForAccount(app.Bech32PrefixAccAddr, app.Bech32PrefixAccPub)
	cfg.SetBech32PrefixForValidator(app.Bech32PrefixValAddr, app.Bech32PrefixValPub)
	cfg.SetBech32PrefixForConsensusNode(app.Bech32PrefixConsAddr, app.Bech32PrefixConsPub)
	cfg.SetAddressVerifier(wasmtypes.VerifyAddressLen())
	cfg.Seal()

	tempDir := tempDir()

	// cleanup temp dir after we are done with the tempApp, so we don't leave behind a
	// new temporary directory for every invocation. See https://github.com/CosmWasm/wasmd/issues/2017
	defer os.RemoveAll(tempDir)
	tempApp := app.NewTerpApp(
		log.NewNopLogger(),
		cosmosdb.NewMemDB(),
		nil,
		true,
		tempDir,
		simtestutil.NewAppOptionsWithFlagHome(tempDir),
		[]wasmkeeper.Option{},
	)

	initClientCtx := client.Context{}.
		WithCodec(encodingConfig.Marshaler).
		WithInterfaceRegistry(encodingConfig.InterfaceRegistry).
		WithTxConfig(encodingConfig.TxConfig).
		WithLegacyAmino(encodingConfig.Amino).
		WithInput(os.Stdin).
		WithAccountRetriever(authtypes.AccountRetriever{}).
		WithBroadcastMode(flags.FlagBroadcastMode).
		WithHomeDir(app.DefaultNodeHome).
		WithViper("") // In terpd, we don't use any prefix for env variables.

	// Allows you to add extra params to your client.toml
	// gas, gas-price, gas-adjustment, fees, note, etc.
	SetCustomEnvVariablesFromClientToml(initClientCtx)

	rootCmd := &cobra.Command{
		Use:   version.AppName,
		Short: "Terp Network Community Network",
		PersistentPreRunE: func(cmd *cobra.Command, _ []string) error {
			// set the default command outputs
			cmd.SetOut(cmd.OutOrStdout())
			cmd.SetErr(cmd.ErrOrStderr())

			initClientCtx, err := client.ReadPersistentCommandFlags(initClientCtx, cmd.Flags())
			if err != nil {
				return err
			}

			initClientCtx, err = config.ReadFromClientConfig(initClientCtx)
			if err != nil {
				return err
			}

			if err := client.SetCmdClientContextHandler(initClientCtx, cmd); err != nil {
				return err
			}

			customAppTemplate, customAppConfig := initAppConfig()
			customTMConfig := tmcfg.DefaultConfig()

			return server.InterceptConfigsPreRunHandler(cmd, customAppTemplate, customAppConfig, customTMConfig)
		},
	}

	initRootCmd(rootCmd, encodingConfig)

	if err := autoCliOpts(initClientCtx, tempApp).EnhanceRootCommand(rootCmd); err != nil {
		panic(err)
	}

	return rootCmd, encodingConfig
}

// initTendermintConfig helps to override default Tendermint Config values.
// return tmcfg.DefaultConfig if no custom configuration is required for the application.
// func initTendermintConfig() *tmcfg.Config {
// 	cfg := tmcfg.DefaultConfig()

// 	// these values put a higher strain on node memory
// 	// cfg.P2P.MaxNumInboundPeers = 100
// 	// cfg.P2P.MaxNumOutboundPeers = 40

// 	return
// }

// initAppConfig helps to override default appConfig template and configs.
// return "", nil if no custom configuration is required for the application.
func initAppConfig() (string, interface{}) {
	// The following code snippet is just for reference.

	type CustomAppConfig struct {
		serverconfig.Config

		Wasm wasmtypes.NodeConfig `mapstructure:"wasm"`

		// SidecarQueryServerConfig sqs.Config `mapstructure:"terp-sqs"`
		// IndexerConfig indexer.Config `mapstructure:"terp-indexer"`
	}

	// Optionally allow the chain developer to overwrite the SDK's default
	// server config.
	srvCfg := serverconfig.DefaultConfig()
	// The SDK's default minimum gas price is set to "" (empty value) inside
	// app.toml. If left empty by validators, the node will halt on startup.
	// However, the chain developer can set a default app.toml value for their
	// validators here.
	//
	// In summary:
	// - if you leave srvCfg.MinGasPrices = "", all validators MUST tweak their
	//   own app.toml config,
	// - if you set srvCfg.MinGasPrices non-empty, validators CAN tweak their
	//   own app.toml to override, or use this default value.
	//
	// In simapp, we set the min gas prices to 0.
	srvCfg.MinGasPrices = "0stake"
	// srvCfg.BaseConfig.IAVLDisableFastNode = true // disable fastnode by default

	terpAppConfig := CustomAppConfig{
		Config: *srvCfg,
		Wasm:   wasmtypes.DefaultNodeConfig(),
	}

	customAppTemplate := serverconfig.DefaultConfigTemplate +
		wasmtypes.DefaultConfigTemplate()

	return customAppTemplate, terpAppConfig
}

// Reads the custom extra values in the config.toml file if set.
// If they are, then use them.
func SetCustomEnvVariablesFromClientToml(ctx client.Context) {
	configFilePath := filepath.Join(ctx.HomeDir, "config", "client.toml")

	if _, err := os.Stat(configFilePath); os.IsNotExist(err) {
		return
	}

	viper := ctx.Viper
	viper.SetConfigFile(configFilePath)

	if err := viper.ReadInConfig(); err != nil {
		panic(err)
	}

	setEnvFromConfig := func(key string, envVar string) {
		// if the user sets the env key manually, then we don't want to override it
		if os.Getenv(envVar) != "" {
			return
		}

		// reads from the config file
		val := viper.GetString(key)
		if val != "" {
			// Sets the env for this instance of the app only.
			os.Setenv(envVar, val)
		}
	}

	// gas
	setEnvFromConfig("gas", "TERPD_GAS")
	setEnvFromConfig("gas-prices", "TERPD_GAS_PRICES")
	setEnvFromConfig("gas-adjustment", "TERPD_GAS_ADJUSTMENT")
	// fees
	setEnvFromConfig("fees", "TERPD_FEES")
	setEnvFromConfig("fee-account", "TERPD_FEE_ACCOUNT")
	// memo
	setEnvFromConfig("note", "TERPD_NOTE")
}

func initRootCmd(rootCmd *cobra.Command, encodingConfig params.EncodingConfig) {
	ac := appCreator{
		encCfg: encodingConfig,
	}

	rootCmd.AddCommand(
		genutilcli.InitCmd(app.ModuleBasics, app.DefaultNodeHome),
		AddGenesisIcaCmd(app.DefaultNodeHome),
		tmcli.NewCompletionCmd(rootCmd, true),
		DebugCmd(),
		ConfigCmd(),
		pruning.Cmd(ac.newApp, app.DefaultNodeHome),
	)

	server.AddTestnetCreatorCommand(rootCmd, ac.newTestnetApp, addModuleInitFlags)
	server.AddCommands(rootCmd, app.DefaultNodeHome, ac.newApp, ac.appExport, addModuleInitFlags)
	wasmcli.ExtendUnsafeResetAllCmd(rootCmd)

	// add keybase, auxiliary RPC, query, and tx child commands
	rootCmd.AddCommand(
		server.StatusCommand(),
		genesisCommand(encodingConfig),
		queryCommand(),
		txCommand(),
		keys.Commands(),
	)
	// add rosetta
	// rootCmd.AddCommand(rosettaCmd.RosettaCommand(encodingConfig.InterfaceRegistry, encodingConfig.Marshaler))
}

func addModuleInitFlags(startCmd *cobra.Command) {
	crisis.AddModuleInitFlags(startCmd)
	wasm.AddModuleInitFlags(startCmd)
}

// genesisCommand builds genesis-related `simd genesis` command. Users may provide application specific commands as a parameter
func genesisCommand(encodingConfig params.EncodingConfig, cmds ...*cobra.Command) *cobra.Command {
	cmd := genutilcli.GenesisCoreCommand(encodingConfig.TxConfig, app.ModuleBasics, app.DefaultNodeHome)

	for _, subCmd := range cmds {
		cmd.AddCommand(subCmd)
	}
	return cmd
}

func queryCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:                        "query",
		Aliases:                    []string{"q"},
		Short:                      "Querying subcommands",
		DisableFlagParsing:         false,
		SuggestionsMinimumDistance: 2,
		RunE:                       client.ValidateCmd,
	}

	cmd.AddCommand(
		rpc.ValidatorCommand(),
		authcmd.QueryTxsByEventsCmd(),
		authcmd.QueryTxCmd(),
	)

	app.ModuleBasics.AddQueryCommands(cmd)

	cmd.PersistentFlags().String(flags.FlagChainID, "", "The network chain ID")

	return cmd
}

func txCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:                        "tx",
		Short:                      "Transactions subcommands",
		DisableFlagParsing:         false,
		SuggestionsMinimumDistance: 2,
		RunE:                       client.ValidateCmd,
	}

	cmd.AddCommand(
		authcmd.GetSignCommand(),
		authcmd.GetSignBatchCommand(),
		authcmd.GetMultiSignCommand(),
		authcmd.GetMultiSignBatchCmd(),
		authcmd.GetValidateSignaturesCommand(),
		flags.LineBreak,
		authcmd.GetBroadcastCommand(),
		authcmd.GetEncodeCommand(),
		authcmd.GetDecodeCommand(),
		// authcmd.GetAuxToFeeCommand(),
	)

	cmd.PersistentFlags().String(flags.FlagChainID, "", "The network chain ID")

	return cmd
}

type appCreator struct {
	encCfg params.EncodingConfig
}

// newApp creates the application
func (ac appCreator) newApp(
	logger log.Logger,
	db cosmosdb.DB,
	traceStore io.Writer,
	appOpts servertypes.AppOptions,
) servertypes.Application {
	skipUpgradeHeights := make(map[int64]bool)
	for _, h := range cast.ToIntSlice(appOpts.Get(server.FlagUnsafeSkipUpgrades)) {
		skipUpgradeHeights[int64(h)] = true
	}

	var wasmOpts []wasmkeeper.Option
	if cast.ToBool(appOpts.Get("telemetry.enabled")) {
		wasmOpts = append(wasmOpts, wasmkeeper.WithVMCacheMetrics(prometheus.DefaultRegisterer))
	}

	loadLatest := true

	baseappOptions := server.DefaultBaseappOptions(appOpts)

	return app.NewTerpApp(
		logger,
		db,
		traceStore,
		loadLatest,
		cast.ToString(appOpts.Get(flags.FlagHome)),
		appOpts,
		wasmOpts,
		baseappOptions...,
	)
}

// appExport creates a new wasm app (optionally at a given height) and exports state.
func (ac appCreator) appExport(
	logger log.Logger,
	db cosmosdb.DB,
	traceStore io.Writer,
	height int64,
	forZeroHeight bool,
	jailAllowedAddrs []string,
	appOpts servertypes.AppOptions,
	modulesToExport []string,
) (servertypes.ExportedApp, error) {
	var wasmApp *app.TerpApp
	homePath, ok := appOpts.Get(flags.FlagHome).(string)
	if !ok || homePath == "" {
		return servertypes.ExportedApp{}, errors.New("application home is not set")
	}

	viperAppOpts, ok := appOpts.(*viper.Viper)
	if !ok {
		return servertypes.ExportedApp{}, errors.New("appOpts is not viper.Viper")
	}

	// overwrite the FlagInvCheckPeriod
	viperAppOpts.Set(server.FlagInvCheckPeriod, 1)
	appOpts = viperAppOpts

	var emptyWasmOpts []wasmkeeper.Option
	wasmApp = app.NewTerpApp(
		logger,
		db,
		traceStore,
		height == -1,
		cast.ToString(appOpts.Get(flags.FlagHome)),
		appOpts,
		emptyWasmOpts,
	)

	if height != -1 {
		if err := wasmApp.LoadHeight(height); err != nil {
			return servertypes.ExportedApp{}, err
		}
	}

	return wasmApp.ExportAppStateAndValidators(forZeroHeight, jailAllowedAddrs, modulesToExport)
}

func autoCliOpts(initClientCtx client.Context, tempApp *app.TerpApp) autocli.AppOptions {
	modules := make(map[string]appmodule.AppModule, 0)
	for _, m := range tempApp.ModuleManager().Modules {
		if moduleWithName, ok := m.(module.HasName); ok {
			moduleName := moduleWithName.Name()
			if appModule, ok := moduleWithName.(appmodule.AppModule); ok {
				modules[moduleName] = appModule
			}
		}
	}

	return autocli.AppOptions{
		Modules:               modules,
		ModuleOptions:         runtimeservices.ExtractAutoCLIOptions(tempApp.ModuleManager().Modules),
		AddressCodec:          authcodec.NewBech32Codec(sdk.GetConfig().GetBech32AccountAddrPrefix()),
		ValidatorAddressCodec: authcodec.NewBech32Codec(sdk.GetConfig().GetBech32ValidatorAddrPrefix()),
		ConsensusAddressCodec: authcodec.NewBech32Codec(sdk.GetConfig().GetBech32ConsensusAddrPrefix()),
		ClientCtx:             initClientCtx,
	}
}

var tempDir = func() string {
	dir, err := os.MkdirTemp("", "terpd")
	if err != nil {
		panic("failed to create temp dir: " + err.Error())
	}

	return dir
}

// newTestnetApp starts by running the normal newApp method. From there, the app interface returned is modified in order
// for a testnet to be created from the provided app.
func (ac appCreator) newTestnetApp(logger log.Logger, db cosmosdb.DB, traceStore io.Writer, appOpts servertypes.AppOptions) servertypes.Application {
	// Create an app and type cast to an TerpApp
	cosmosApp := ac.newApp(logger, db, traceStore, appOpts)
	terpApp, ok := cosmosApp.(*app.TerpApp)
	if !ok {
		panic("app created from newApp is not of type terpApp")
	}

	newValAddr, ok := appOpts.Get(server.KeyNewValAddr).(bytes.HexBytes)
	if !ok {
		panic("newValAddr is not of type bytes.HexBytes")
	}
	newValPubKey, ok := appOpts.Get(server.KeyUserPubKey).(crypto.PubKey)
	if !ok {
		panic("newValPubKey is not of type crypto.PubKey")
	}
	newOperatorAddress, ok := appOpts.Get(server.KeyNewOpAddr).(string)
	if !ok {
		panic("newOperatorAddress is not of type string")
	}
	upgradeToTrigger, ok := appOpts.Get(server.KeyTriggerTestnetUpgrade).(string)
	if !ok {
		panic("upgradeToTrigger is not of type string")
	}

	// if !ok {
	// 	panic("cannot parse broken validators strings")
	// }

	// brokenVals := strings.Split(brokenValidators, ",")
	// fmt.Printf("brokenVals: %v\n", brokenVals)

	// get the json file to additional vals powers
	// newValsPowerJson, ok := appOpts.Get(testnetserver.KeyNewValsPowerJson).(string)
	// if !ok {
	// 	panic(fmt.Errorf("expected path to new validators json %s", testnetserver.KeyNewValsPowerJson))
	// }

	//  parse json to get list of validators
	// [{"val":  "terp1val...", "num_dels": , "num_tokens": ,"jailed": }]
	// newValsPower, err := testnetserver.ParseValidatorInfos(newValsPowerJson)
	// if err != nil {
	// 	panic(fmt.Errorf("error parsing validator infos %v ", err))
	// }
	// fmt.Printf("newValsPower: %v\n", newValsPower)

	// Make modifications to the normal TerpApp required to run the network locally
	return app.InitTerpAppForTestnet(terpApp, newValAddr, newValPubKey, newOperatorAddress, upgradeToTrigger, newOperatorAddress) // newValsPower
}
