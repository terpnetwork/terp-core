package server

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	cmtcfg "github.com/cometbft/cometbft/config"
	cmtjson "github.com/cometbft/cometbft/libs/json"
	"github.com/cometbft/cometbft/node"
	pvm "github.com/cometbft/cometbft/privval"
	cmtstate "github.com/cometbft/cometbft/proto/tendermint/state"
	cmtproto "github.com/cometbft/cometbft/proto/tendermint/types"
	"github.com/cometbft/cometbft/proxy"
	sm "github.com/cometbft/cometbft/state"
	"github.com/cometbft/cometbft/store"
	cmttypes "github.com/cometbft/cometbft/types"
	dbm "github.com/cosmos/cosmos-db"
	"github.com/cosmos/cosmos-sdk/client"
	"github.com/cosmos/cosmos-sdk/server"
	terpserver "github.com/cosmos/cosmos-sdk/server"
	"github.com/cosmos/cosmos-sdk/server/types"
	genutiltypes "github.com/cosmos/cosmos-sdk/x/genutil/types"
	"github.com/spf13/cobra"
)

// AddTestnetCreatorCommand allows chains to create a testnet from the state existing in their node's data directory.
func AddTestnetCreatorCommand(rootCmd *cobra.Command, appCreator types.AppCreator, addStartFlags types.ModuleInitFlags) {
	testnetCreateCmd := InPlaceTestnetCreator(appCreator)
	addStartFlags(testnetCreateCmd)
	rootCmd.AddCommand(testnetCreateCmd)
}

// InPlaceTestnetCreator utilizes the provided chainID and operatorAddress as well as the local private validator key to
// control the network represented in the data folder. This is useful to create testnets nearly identical to your
// mainnet environment.
func InPlaceTestnetCreator(testnetAppCreator types.AppCreator) *cobra.Command {
	opts := StartCmdOptions{}
	if opts.DBOpener == nil {
		opts.DBOpener = openDB
	}

	if opts.StartCommandHandler == nil {
		opts.StartCommandHandler = start
	}

	cmd := &cobra.Command{
		Use:   "in-place-testnet [newChainID] [newOperatorAddress]",
		Short: "Create and start a testnet from current local state",
		Long: `Create and start a testnet from current local state.
After utilizing this command the network will start. If the network is stopped,
the normal "start" command should be used. Re-using this command on state that
has already been modified by this command could result in unexpected behavior.

Additionally, the first block may take up to one minute to be committed, depending
on how old the block is. For instance, if a snapshot was taken weeks ago and we want
to turn this into a testnet, it is possible lots of pending state needs to be committed
(expiring locks, etc.). It is recommended that you should wait for this block to be committed
before stopping the daemon.

If the --trigger-testnet-upgrade flag is set, the upgrade handler specified by the flag will be run
on the first block of the testnet.

Regardless of whether the flag is set or not, if any new stores are introduced in the daemon being run,
those stores will be registered in order to prevent panics. Therefore, you only need to set the flag if
you want to test the upgrade handler itself.
`,
		Example: "in-place-testnet localterp terp12smx2wdlyttvyzvzg54y2vnqwq2qjatencyhtn",
		Args:    cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			serverCtx := terpserver.GetServerContextFromCmd(cmd)
			_, err := terpserver.GetPruningOptionsFromFlags(serverCtx.Viper)
			if err != nil {
				return err
			}

			clientCtx, err := client.GetClientQueryContext(cmd)
			if err != nil {
				return err
			}

			withCMT, _ := cmd.Flags().GetBool(flagWithComet)
			if !withCMT {
				serverCtx.Logger.Info("starting ABCI without CometBFT")
			}

			newChainID := args[0]
			newOperatorAddress := args[1]

			skipConfirmation, _ := cmd.Flags().GetBool("skip-confirmation")

			if !skipConfirmation {
				// Confirmation prompt to prevent accidental modification of state.
				reader := bufio.NewReader(os.Stdin)
				fmt.Println("This operation will modify state in your data folder and cannot be undone. Do you want to continue? (y/n)")
				text, _ := reader.ReadString('\n')
				response := strings.TrimSpace(strings.ToLower(text))
				if response != "y" && response != "yes" {
					fmt.Println("Operation canceled.")
					return nil
				}
			}

			// Set testnet keys to be used by the application.
			// This is done to prevent changes to existing start API.
			serverCtx.Viper.Set(KeyIsTestnet, true)
			serverCtx.Viper.Set(KeyNewChainID, newChainID)
			serverCtx.Viper.Set(KeyNewOpAddr, newOperatorAddress)

			err = wrapCPUProfile(serverCtx, func() error {
				return opts.StartCommandHandler(serverCtx, clientCtx, testnetAppCreator, withCMT, opts)
			})

			serverCtx.Logger.Debug("received quit signal")
			graceDuration, _ := cmd.Flags().GetDuration(FlagShutdownGrace)
			if graceDuration > 0 {
				serverCtx.Logger.Info("graceful shutdown start", FlagShutdownGrace, graceDuration)
				<-time.After(graceDuration)
				serverCtx.Logger.Info("graceful shutdown complete")
			}

			return err
		},
	}

	addStartNodeFlags(cmd, opts)
	cmd.Flags().String(KeyTriggerTestnetUpgrade, "", "If set (example: \"v21\"), triggers the v21 upgrade handler to run on the first block of the testnet")
	cmd.Flags().Bool("skip-confirmation", false, "Skip the confirmation prompt")
	return cmd
}

// testnetify modifies both state and blockStore, allowing the provided operator address and local validator key to control the network
// that the state in the data folder represents. The chainID of the local genesis file is modified to match the provided chainID.
// testnetify modifies both state and blockStore, allowing the provided operator address and local validator key to control the network
// that the state in the data folder represents. The chainID of the local genesis file is modified to match the provided chainID.
func testnetify(ctx *server.Context, testnetAppCreator types.AppCreator, db dbm.DB, traceWriter io.WriteCloser) (types.Application, error) {
	config := ctx.Config

	newChainID, ok := ctx.Viper.Get(KeyNewChainID).(string)
	if !ok {
		return nil, fmt.Errorf("expected string for key %s", KeyNewChainID)
	}

	// Modify app genesis chain ID and save to genesis file.
	genFilePath := config.GenesisFile()
	appGen, err := genutiltypes.AppGenesisFromFile(genFilePath)
	if err != nil {
		return nil, err
	}
	appGen.ChainID = newChainID
	if err := appGen.ValidateAndComplete(); err != nil {
		return nil, err
	}
	if err := appGen.SaveAs(genFilePath); err != nil {
		return nil, err
	}

	// Regenerate addrbook.json to prevent peers on old network from causing error logs.
	addrBookPath := filepath.Join(config.RootDir, "config", "addrbook.json")
	if err := os.Remove(addrBookPath); err != nil && !os.IsNotExist(err) {
		return nil, fmt.Errorf("failed to remove existing addrbook.json: %w", err)
	}

	emptyAddrBook := []byte("{}")
	if err := os.WriteFile(addrBookPath, emptyAddrBook, 0o600); err != nil {
		return nil, fmt.Errorf("failed to create empty addrbook.json: %w", err)
	}

	// Load the comet genesis doc provider.
	genDocProvider := node.DefaultGenesisDocProviderFunc(config)

	// Initialize blockStore and stateDB.
	blockStoreDB, err := cmtcfg.DefaultDBProvider(&cmtcfg.DBContext{ID: "blockstore", Config: config})
	if err != nil {
		return nil, err
	}
	blockStore := store.NewBlockStore(blockStoreDB)

	stateDB, err := cmtcfg.DefaultDBProvider(&cmtcfg.DBContext{ID: "state", Config: config})
	if err != nil {
		return nil, err
	}

	defer blockStore.Close()
	defer stateDB.Close()

	privValidator := pvm.LoadOrGenFilePV(config.PrivValidatorKeyFile(), config.PrivValidatorStateFile())
	userPubKey, err := privValidator.GetPubKey()
	if err != nil {
		return nil, err
	}
	validatorAddress := userPubKey.Address()

	stateStore := sm.NewStore(stateDB, sm.StoreOptions{
		DiscardABCIResponses: config.Storage.DiscardABCIResponses,
	})

	state, genDoc, err := node.LoadStateFromDBOrGenesisDocProvider(stateDB, genDocProvider)
	if err != nil {
		return nil, err
	}

	ctx.Viper.Set(KeyNewValAddr, validatorAddress)
	ctx.Viper.Set(KeyUserPubKey, userPubKey)
	testnetApp := testnetAppCreator(ctx.Logger, db, ctx.Viper)

	// We need to create a temporary proxyApp to get the initial state of the application.
	cmtApp := server.NewCometABCIWrapper(testnetApp)
	_, context := getCtx(ctx, true)
	clientCreator := proxy.NewLocalClientCreator(cmtApp)
	metrics := node.DefaultMetricsProvider(cmtcfg.DefaultConfig().Instrumentation)
	_, _, _, _, proxyMetrics, _, _ := metrics(genDoc.ChainID)
	proxyApp := proxy.NewAppConns(clientCreator, proxyMetrics)
	if err := proxyApp.Start(); err != nil {
		return nil, fmt.Errorf("error starting proxy app connections: %v", err)
	}
	res, err := proxyApp.Query().Info(context, proxy.RequestInfo)
	if err != nil {
		return nil, fmt.Errorf("error calling Info: %v", err)
	}
	err = proxyApp.Stop()
	if err != nil {
		return nil, err
	}
	appHash := res.LastBlockAppHash
	appHeight := res.LastBlockHeight

	var block *cmttypes.Block
	switch {
	case appHeight == blockStore.Height():
		block = blockStore.LoadBlock(blockStore.Height())
		if state.LastBlockHeight != appHeight {
			state.LastBlockHeight = appHeight
			block.AppHash = appHash
			state.AppHash = appHash
		} else {
			// Node was likely stopped via SIGTERM, delete the next block's seen commit
			err := blockStoreDB.Delete([]byte(fmt.Sprintf("SC:%v", blockStore.Height()+1)))
			if err != nil {
				return nil, err
			}
		}
	case blockStore.Height() > state.LastBlockHeight:
		// This state usually occurs when we gracefully stop the node.
		err = blockStore.DeleteLatestBlock()
		if err != nil {
			return nil, err
		}
		block = blockStore.LoadBlock(blockStore.Height())
	default:
		// If there is any other state, we just load the block
		block = blockStore.LoadBlock(blockStore.Height())
	}

	block.ChainID = newChainID
	state.ChainID = newChainID

	block.LastBlockID = state.LastBlockID
	block.LastCommit.BlockID = state.LastBlockID

	// Create a vote from our validator
	vote := cmttypes.Vote{
		Type:             cmtproto.PrecommitType,
		Height:           state.LastBlockHeight,
		Round:            0,
		BlockID:          state.LastBlockID,
		Timestamp:        time.Now(),
		ValidatorAddress: validatorAddress,
		ValidatorIndex:   0,
		Signature:        []byte{},
	}

	// Sign the vote, and copy the proto changes from the act of signing to the vote itself
	voteProto := vote.ToProto()
	err = privValidator.SignVote(newChainID, voteProto)
	if err != nil {
		return nil, err
	}
	vote.Signature = voteProto.Signature
	vote.Timestamp = voteProto.Timestamp

	// Modify the block's lastCommit to be signed only by our validator
	block.LastCommit.Signatures[0].ValidatorAddress = validatorAddress
	block.LastCommit.Signatures[0].Signature = vote.Signature
	block.LastCommit.Signatures = []cmttypes.CommitSig{block.LastCommit.Signatures[0]}

	// Load the extendedCommit of the lastBlockHeight and modify it to be signed from our validator
	ec := blockStore.LoadBlockExtendedCommit(state.LastBlockHeight)
	ec.BlockID = state.LastBlockID
	ec.Round = vote.Round
	ec.ExtendedSignatures[0].Signature = vote.Signature
	ec.ExtendedSignatures[0].ValidatorAddress = validatorAddress
	ec.ExtendedSignatures[0].Timestamp = vote.Timestamp
	ec.ExtendedSignatures[0].BlockIDFlag = cmttypes.BlockIDFlagCommit

	extSignBytes := cmttypes.VoteExtensionSignBytes(newChainID, vote.ToProto())
	extSig, err := privValidator.Key.PrivKey.Sign(extSignBytes)
	if err != nil {
		return nil, err
	}

	ec.ExtendedSignatures[0].ExtensionSignature = extSig
	ec.ExtendedSignatures = []cmttypes.ExtendedCommitSig{ec.ExtendedSignatures[0]}

	// Create the part set from the block
	blockParts, err := block.MakePartSet(cmttypes.BlockPartSizeBytes)
	if err != nil {
		return nil, err
	}

	// Save the block with extended commit
	blockStore.DeleteLatestBlock()
	blockStore.SaveBlockWithExtendedCommit(block, blockParts, ec)

	// Create a list to store validators
	var newValidators []*cmttypes.Validator

	// Add our validator with high voting power
	newVal := &cmttypes.Validator{
		Address:     validatorAddress,
		PubKey:      userPubKey,
		VotingPower: 900000000000000,
	}
	newValidators = append(newValidators, newVal)

	// Create new validator set
	newValSet := &cmttypes.ValidatorSet{
		Validators: newValidators,
		Proposer:   newVal, // Our validator remains the proposer
	}

	// Replace all valSets in state to be the new valSet
	state.Validators = newValSet
	state.LastValidators = newValSet
	state.NextValidators = newValSet
	state.LastHeightValidatorsChanged = blockStore.Height()

	err = stateStore.Save(state)
	if err != nil {
		return nil, err
	}

	// Create a ValidatorsInfo struct to store in stateDB
	valSet, err := state.Validators.ToProto()
	if err != nil {
		return nil, err
	}
	valInfo := &cmtstate.ValidatorsInfo{
		ValidatorSet:      valSet,
		LastHeightChanged: state.LastBlockHeight,
	}
	buf, err := valInfo.Marshal()
	if err != nil {
		return nil, err
	}

	// Modify Validators stateDB entries
	for _, height := range []int64{blockStore.Height(), blockStore.Height() - 1, blockStore.Height() + 1} {
		err = stateDB.Set([]byte(fmt.Sprintf("validatorsKey:%v", height)), buf)
		if err != nil {
			return nil, err
		}
	}

	// Since we modified the chainID, we set the new genesisDoc in the stateDB
	b, err := cmtjson.Marshal(genDoc)
	if err != nil {
		return nil, err
	}
	if err := stateDB.SetSync([]byte("genesisDoc"), b); err != nil {
		return nil, err
	}

	return testnetApp, err
}
