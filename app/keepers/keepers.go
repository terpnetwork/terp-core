package keepers

import (
	"fmt"

	"github.com/spf13/cast"

	"github.com/cosmos/cosmos-sdk/baseapp"
	"github.com/cosmos/cosmos-sdk/client/flags"
	"github.com/cosmos/cosmos-sdk/codec"
	"github.com/cosmos/cosmos-sdk/runtime"
	"github.com/cosmos/cosmos-sdk/server"

	"cosmossdk.io/x/feegrant"
	"cosmossdk.io/x/nft"

	"github.com/CosmWasm/wasmd/x/wasm"
	wasmkeeper "github.com/CosmWasm/wasmd/x/wasm/keeper"
	wasmtypes "github.com/CosmWasm/wasmd/x/wasm/types"
	wasmvm "github.com/CosmWasm/wasmvm/v3"
	ibcwlckeeper "github.com/cosmos/ibc-go/modules/light-clients/08-wasm/v10/keeper"
	ibcwlctypes "github.com/cosmos/ibc-go/modules/light-clients/08-wasm/v10/types"
	appparams "github.com/terpnetwork/terp-core/v5/app/params"

	"github.com/cosmos/ibc-apps/middleware/packet-forward-middleware/v10/packetforward"
	packetforwardkeeper "github.com/cosmos/ibc-apps/middleware/packet-forward-middleware/v10/packetforward/keeper"
	packetforwardtypes "github.com/cosmos/ibc-apps/middleware/packet-forward-middleware/v10/packetforward/types"

	ibchooks "github.com/cosmos/ibc-apps/modules/ibc-hooks/v10"
	ibchookskeeper "github.com/cosmos/ibc-apps/modules/ibc-hooks/v10/keeper"
	ibchookstypes "github.com/cosmos/ibc-apps/modules/ibc-hooks/v10/types"

	icacontroller "github.com/cosmos/ibc-go/v10/modules/apps/27-interchain-accounts/controller"
	icacontrollerkeeper "github.com/cosmos/ibc-go/v10/modules/apps/27-interchain-accounts/controller/keeper"
	icacontrollertypes "github.com/cosmos/ibc-go/v10/modules/apps/27-interchain-accounts/controller/types"

	icahost "github.com/cosmos/ibc-go/v10/modules/apps/27-interchain-accounts/host"
	icahostkeeper "github.com/cosmos/ibc-go/v10/modules/apps/27-interchain-accounts/host/keeper"
	icahosttypes "github.com/cosmos/ibc-go/v10/modules/apps/27-interchain-accounts/host/types"
	icatypes "github.com/cosmos/ibc-go/v10/modules/apps/27-interchain-accounts/types"

	transfer "github.com/cosmos/ibc-go/v10/modules/apps/transfer"

	ibctransferkeeper "github.com/cosmos/ibc-go/v10/modules/apps/transfer/keeper"
	ibctransfertypes "github.com/cosmos/ibc-go/v10/modules/apps/transfer/types"
	ibcclienttypes "github.com/cosmos/ibc-go/v10/modules/core/02-client/types"
	ibcconnectiontypes "github.com/cosmos/ibc-go/v10/modules/core/03-connection/types"

	porttypes "github.com/cosmos/ibc-go/v10/modules/core/05-port/types"
	ibcexported "github.com/cosmos/ibc-go/v10/modules/core/exported"
	ibckeeper "github.com/cosmos/ibc-go/v10/modules/core/keeper"

	storetypes "cosmossdk.io/store/types"
	evidencekeeper "cosmossdk.io/x/evidence/keeper"
	evidencetypes "cosmossdk.io/x/evidence/types"
	feegrantkeeper "cosmossdk.io/x/feegrant/keeper"

	nftkeeper "cosmossdk.io/x/nft/keeper"
	upgradekeeper "cosmossdk.io/x/upgrade/keeper"
	upgradetypes "cosmossdk.io/x/upgrade/types"

	addresscodec "github.com/cosmos/cosmos-sdk/codec/address"
	servertypes "github.com/cosmos/cosmos-sdk/server/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
	authkeeper "github.com/cosmos/cosmos-sdk/x/auth/keeper"
	authtypes "github.com/cosmos/cosmos-sdk/x/auth/types"
	authzkeeper "github.com/cosmos/cosmos-sdk/x/authz/keeper"
	bankkeeper "github.com/cosmos/cosmos-sdk/x/bank/keeper"
	banktypes "github.com/cosmos/cosmos-sdk/x/bank/types"
	consensusparamkeeper "github.com/cosmos/cosmos-sdk/x/consensus/keeper"
	consensusparamtypes "github.com/cosmos/cosmos-sdk/x/consensus/types"
	crisiskeeper "github.com/cosmos/cosmos-sdk/x/crisis/keeper"
	crisistypes "github.com/cosmos/cosmos-sdk/x/crisis/types"
	distrkeeper "github.com/cosmos/cosmos-sdk/x/distribution/keeper"
	distrtypes "github.com/cosmos/cosmos-sdk/x/distribution/types"
	govkeeper "github.com/cosmos/cosmos-sdk/x/gov/keeper"
	govtypes "github.com/cosmos/cosmos-sdk/x/gov/types"
	govv1beta1 "github.com/cosmos/cosmos-sdk/x/gov/types/v1beta1"
	"github.com/cosmos/cosmos-sdk/x/group"
	groupkeeper "github.com/cosmos/cosmos-sdk/x/group/keeper"
	mintkeeper "github.com/cosmos/cosmos-sdk/x/mint/keeper"
	minttypes "github.com/cosmos/cosmos-sdk/x/mint/types"
	"github.com/cosmos/cosmos-sdk/x/params"
	paramskeeper "github.com/cosmos/cosmos-sdk/x/params/keeper"
	paramstypes "github.com/cosmos/cosmos-sdk/x/params/types"
	paramproposal "github.com/cosmos/cosmos-sdk/x/params/types/proposal"
	slashingkeeper "github.com/cosmos/cosmos-sdk/x/slashing/keeper"
	slashingtypes "github.com/cosmos/cosmos-sdk/x/slashing/types"
	stakingkeeper "github.com/cosmos/cosmos-sdk/x/staking/keeper"
	stakingtypes "github.com/cosmos/cosmos-sdk/x/staking/types"

	dripkeeper "github.com/terpnetwork/terp-core/v5/x/drip/keeper"
	driptypes "github.com/terpnetwork/terp-core/v5/x/drip/types"
	feesharekeeper "github.com/terpnetwork/terp-core/v5/x/feeshare/keeper"
	feesharetypes "github.com/terpnetwork/terp-core/v5/x/feeshare/types"

	"github.com/terpnetwork/terp-core/v5/x/globalfee"
	globalfeekeeper "github.com/terpnetwork/terp-core/v5/x/globalfee/keeper"
	globalfeetypes "github.com/terpnetwork/terp-core/v5/x/globalfee/types"

	"github.com/terpnetwork/terp-core/v5/x/smart-account/authenticator"
	smartaccountkeeper "github.com/terpnetwork/terp-core/v5/x/smart-account/keeper"
	smartaccounttypes "github.com/terpnetwork/terp-core/v5/x/smart-account/types"

	// cwhookskeeper "github.com/terpnetwork/terp-core/v5/x/cw-hooks/keeper"
	// cwhookstypes "github.com/terpnetwork/terp-core/v5/x/cw-hooks/types"

	tokenfactorykeeper "github.com/terpnetwork/terp-core/v5/x/tokenfactory/keeper"
	tokenfactorytypes "github.com/terpnetwork/terp-core/v5/x/tokenfactory/types"
	// terpwasm "github.com/terpnetwork/terp-core/v5/internal/wasm"
)

var (
	EmptyWasmOpts []wasmkeeper.Option
	Bech32Prefix  = "terp"
)

// module account permissions
var maccPerms = map[string][]string{
	authtypes.FeeCollectorName:     nil,
	distrtypes.ModuleName:          nil,
	minttypes.ModuleName:           {authtypes.Minter},
	stakingtypes.BondedPoolName:    {authtypes.Burner, authtypes.Staking},
	stakingtypes.NotBondedPoolName: {authtypes.Burner, authtypes.Staking},
	govtypes.ModuleName:            {authtypes.Burner},
	nft.ModuleName:                 nil,
	ibctransfertypes.ModuleName:    {authtypes.Minter, authtypes.Burner},
	icatypes.ModuleName:            nil,
	globalfee.ModuleName:           nil,
	wasmtypes.ModuleName:           {authtypes.Burner},
	tokenfactorytypes.ModuleName:   {authtypes.Minter, authtypes.Burner},
}

type AppKeepers struct {
	// keys to access the substores
	keys    map[string]*storetypes.KVStoreKey
	tkeys   map[string]*storetypes.TransientStoreKey
	memKeys map[string]*storetypes.MemoryStoreKey

	// keepers
	AccountKeeper *authkeeper.AccountKeeper
	AuthzKeeper   *authzkeeper.Keeper
	BankKeeper    bankkeeper.BaseKeeper

	StakingKeeper         *stakingkeeper.Keeper
	SlashingKeeper        *slashingkeeper.Keeper
	MintKeeper            *mintkeeper.Keeper
	DistrKeeper           *distrkeeper.Keeper
	GovKeeper             *govkeeper.Keeper
	CrisisKeeper          *crisiskeeper.Keeper
	UpgradeKeeper         *upgradekeeper.Keeper
	ParamsKeeper          paramskeeper.Keeper
	EvidenceKeeper        *evidencekeeper.Keeper
	FeeGrantKeeper        *feegrantkeeper.Keeper
	GroupKeeper           *groupkeeper.Keeper
	NFTKeeper             *nftkeeper.Keeper
	ConsensusParamsKeeper *consensusparamkeeper.Keeper

	IBCKeeper            *ibckeeper.Keeper // IBC Keeper must be a pointer in the app, so we can SetRouter on it correctly
	IBCHooksKeeper       *ibchookskeeper.Keeper
	ICAControllerKeeper  *icacontrollerkeeper.Keeper
	FeeShareKeeper       *feesharekeeper.Keeper
	GlobalFeeKeeper      *globalfeekeeper.Keeper
	TokenFactoryKeeper   *tokenfactorykeeper.Keeper
	PacketForwardKeeper  *packetforwardkeeper.Keeper
	ICAHostKeeper        *icahostkeeper.Keeper
	TransferKeeper       *ibctransferkeeper.Keeper
	SmartAccountKeeper   *smartaccountkeeper.Keeper
	AuthenticatorManager *authenticator.AuthenticatorManager
	ContractKeeper       *wasmkeeper.PermissionedKeeper
	WasmKeeper           *wasmkeeper.Keeper
	IBCWasmClientKeeper  *ibcwlckeeper.Keeper

	DripKeeper dripkeeper.Keeper

	// Middleware wrapper
	Ics20WasmHooks   *ibchooks.WasmHooks
	HooksICS4Wrapper ibchooks.ICS4Middleware
}

func NewAppKeepers(
	appCodec codec.Codec,
	encodingConfig appparams.EncodingConfig,
	bApp *baseapp.BaseApp,
	cdc *codec.LegacyAmino,
	maccPerms map[string][]string,
	appOpts servertypes.AppOptions,
	wasmOpts []wasmkeeper.Option,
	wasmDir string,
	wasmConfig wasmtypes.NodeConfig,
	ibcWasmConfig ibcwlctypes.WasmConfig,
) AppKeepers {
	appKeepers := AppKeepers{}

	// Set keys KVStoreKey, TransientStoreKey, MemoryStoreKey
	appKeepers.GenerateKeys()
	keys := appKeepers.GetKVStoreKey()
	tkeys := appKeepers.GetTransientStoreKey()

	appKeepers.ParamsKeeper = initParamsKeeper(
		appCodec,
		cdc,
		keys[paramstypes.StoreKey],
		tkeys[paramstypes.TStoreKey],
	)

	govModAddress := authtypes.NewModuleAddress(govtypes.ModuleName).String()

	// set the BaseApp's parameter store
	consensusParamsKeeper := consensusparamkeeper.NewKeeper(
		appCodec,
		runtime.NewKVStoreService(appKeepers.keys[consensusparamtypes.StoreKey]),
		govModAddress,
		runtime.EventService{},
	)
	appKeepers.ConsensusParamsKeeper = &consensusParamsKeeper
	bApp.SetParamStore(&appKeepers.ConsensusParamsKeeper.ParamsStore)

	// add keepers

	accountKeeper := authkeeper.NewAccountKeeper(
		appCodec,
		runtime.NewKVStoreService(appKeepers.keys[authtypes.StoreKey]),
		authtypes.ProtoBaseAccount,
		maccPerms,
		addresscodec.NewBech32Codec(sdk.GetConfig().GetBech32AccountAddrPrefix()),
		Bech32Prefix,
		govModAddress,
	)
	appKeepers.AccountKeeper = &accountKeeper

	appKeepers.BankKeeper = bankkeeper.NewBaseKeeper(
		appCodec,
		runtime.NewKVStoreService(appKeepers.keys[banktypes.StoreKey]),
		appKeepers.AccountKeeper,
		BlockedAddresses(),
		govModAddress,
		bApp.Logger(),
	)

	stakingKeeper := stakingkeeper.NewKeeper(
		appCodec,
		runtime.NewKVStoreService(appKeepers.keys[stakingtypes.StoreKey]),
		appKeepers.AccountKeeper,
		appKeepers.BankKeeper,
		govModAddress,
		addresscodec.NewBech32Codec(sdk.GetConfig().GetBech32ValidatorAddrPrefix()),
		addresscodec.NewBech32Codec(sdk.GetConfig().GetBech32ConsensusAddrPrefix()),
	)

	mintKeeper := mintkeeper.NewKeeper(
		appCodec,
		runtime.NewKVStoreService(appKeepers.keys[minttypes.StoreKey]),
		stakingKeeper,
		appKeepers.AccountKeeper,
		appKeepers.BankKeeper,
		authtypes.FeeCollectorName,
		govModAddress,
	)
	appKeepers.MintKeeper = &mintKeeper

	feegrantKeeper := feegrantkeeper.NewKeeper(
		appCodec, runtime.NewKVStoreService(appKeepers.keys[feegrant.StoreKey]), appKeepers.AccountKeeper,
	)
	appKeepers.FeeGrantKeeper = &feegrantKeeper

	// Initialize authenticators
	appKeepers.AuthenticatorManager = authenticator.NewAuthenticatorManager()
	appKeepers.AuthenticatorManager.InitializeAuthenticators([]authenticator.Authenticator{
		authenticator.NewSignatureVerification(appKeepers.AccountKeeper),
		authenticator.NewMessageFilter(encodingConfig),
		authenticator.NewAllOf(appKeepers.AuthenticatorManager),
		authenticator.NewAnyOf(appKeepers.AuthenticatorManager),
		authenticator.NewPartitionedAnyOf(appKeepers.AuthenticatorManager),
		authenticator.NewPartitionedAllOf(appKeepers.AuthenticatorManager),
	})

	smartAccountKeeper := smartaccountkeeper.NewKeeper(
		appCodec,
		appKeepers.keys[smartaccounttypes.StoreKey],
		authtypes.NewModuleAddress(govtypes.ModuleName), appKeepers.GetSubspace(smartaccounttypes.ModuleName),
		appKeepers.AuthenticatorManager,
		*appKeepers.FeeGrantKeeper,
	)
	appKeepers.SmartAccountKeeper = &smartAccountKeeper

	distrKeeper := distrkeeper.NewKeeper(
		appCodec,
		runtime.NewKVStoreService(appKeepers.keys[distrtypes.StoreKey]),
		appKeepers.AccountKeeper,
		appKeepers.BankKeeper,
		stakingKeeper,
		authtypes.FeeCollectorName,
		govModAddress,
	)

	appKeepers.DistrKeeper = &distrKeeper

	slashKeeper := slashingkeeper.NewKeeper(
		appCodec,
		cdc,
		runtime.NewKVStoreService(appKeepers.keys[slashingtypes.StoreKey]),
		stakingKeeper,
		govModAddress,
	)
	appKeepers.SlashingKeeper = &slashKeeper

	invCheckPeriod := cast.ToUint(appOpts.Get(server.FlagInvCheckPeriod))

	appKeepers.CrisisKeeper = crisiskeeper.NewKeeper(
		appCodec,
		runtime.NewKVStoreService(appKeepers.keys[crisistypes.StoreKey]),
		invCheckPeriod,
		appKeepers.BankKeeper,
		authtypes.FeeCollectorName,
		govModAddress,
		addresscodec.NewBech32Codec(sdk.GetConfig().GetBech32AccountAddrPrefix()),
	)

	// get skipUpgradeHeights from the app options
	skipUpgradeHeights := map[int64]bool{}
	for _, h := range cast.ToIntSlice(appOpts.Get(server.FlagUnsafeSkipUpgrades)) {
		skipUpgradeHeights[int64(h)] = true
	}
	homePath := cast.ToString(appOpts.Get(flags.FlagHome))
	// set the governance module account as the authority for conducting upgrades
	appKeepers.UpgradeKeeper = upgradekeeper.NewKeeper(
		skipUpgradeHeights,
		runtime.NewKVStoreService(appKeepers.keys[upgradetypes.StoreKey]),
		appCodec,
		homePath,
		bApp,
		govModAddress,
	)

	// register the staking hooks
	// NOTE: stakingKeeper above is passed by reference, so that it will contain these hooks
	stakingKeeper.SetHooks(
		stakingtypes.NewMultiStakingHooks(appKeepers.DistrKeeper.Hooks(),
			appKeepers.SlashingKeeper.Hooks(),
			// appKeepers.CWHooksKeeper.StakingHooks(),
		),
	)
	appKeepers.StakingKeeper = stakingKeeper

	appKeepers.IBCKeeper = ibckeeper.NewKeeper(
		appCodec,
		runtime.NewKVStoreService(appKeepers.keys[ibcexported.StoreKey]),
		appKeepers.GetSubspace(ibcexported.ModuleName),
		appKeepers.UpgradeKeeper,
		govModAddress,
	)

	authzKeeper := authzkeeper.NewKeeper(
		runtime.NewKVStoreService(appKeepers.keys[authzkeeper.StoreKey]),
		appCodec,
		bApp.MsgServiceRouter(),
		appKeepers.AccountKeeper,
	)
	appKeepers.AuthzKeeper = &authzKeeper

	// Register the proposal types
	govRouter := govv1beta1.NewRouter()
	govRouter.AddRoute(govtypes.RouterKey, govv1beta1.ProposalHandler).
		AddRoute(paramproposal.RouterKey, params.NewParamChangeProposalHandler(appKeepers.ParamsKeeper))

	govConfig := govtypes.DefaultConfig()

	appKeepers.GovKeeper = govkeeper.NewKeeper(
		appCodec,
		runtime.NewKVStoreService(appKeepers.keys[govtypes.StoreKey]),
		appKeepers.AccountKeeper,
		appKeepers.BankKeeper,
		stakingKeeper,
		appKeepers.DistrKeeper,
		bApp.MsgServiceRouter(),
		govConfig,
		govModAddress,
	)
	groupConfig := group.DefaultConfig()
	groupConfig.MaxMetadataLen = 500
	groupKeeper := groupkeeper.NewKeeper(keys[group.StoreKey], appCodec, bApp.MsgServiceRouter(), appKeepers.AccountKeeper, groupConfig)
	appKeepers.GroupKeeper = &groupKeeper

	nftKeeper := nftkeeper.NewKeeper(
		runtime.NewKVStoreService(appKeepers.keys[nftkeeper.StoreKey]),
		appCodec,
		appKeepers.AccountKeeper,
		appKeepers.BankKeeper,
	)
	appKeepers.NFTKeeper = &nftKeeper

	// Configure the hooks keeper
	hooksKeeper := ibchookskeeper.NewKeeper(
		keys[ibchookstypes.StoreKey],
	)
	appKeepers.IBCHooksKeeper = &hooksKeeper

	terpPrefix := sdk.GetConfig().GetBech32AccountAddrPrefix()
	wasmHooks := ibchooks.NewWasmHooks(appKeepers.IBCHooksKeeper, appKeepers.WasmKeeper, terpPrefix) // The contract keeper needs to be set later // The contract keeper needs to be set later
	appKeepers.Ics20WasmHooks = &wasmHooks
	appKeepers.HooksICS4Wrapper = ibchooks.NewICS4Middleware(
		appKeepers.IBCKeeper.ChannelKeeper,
		appKeepers.Ics20WasmHooks,
	)

	// Initialize packet forward middleware router (BEFORE transferKeeper)
	appKeepers.PacketForwardKeeper = packetforwardkeeper.NewKeeper(
		appCodec,
		runtime.NewKVStoreService(appKeepers.keys[packetforwardtypes.StoreKey]),
		nil, // Will be zero-value here. Reference is set later on with SetTransferKeeper.
		appKeepers.IBCKeeper.ChannelKeeper,
		appKeepers.BankKeeper,
		appKeepers.HooksICS4Wrapper,
		govModAddress,
	)

	// Create Transfer Keepers
	transferKeeper := ibctransferkeeper.NewKeeper(
		appCodec,
		runtime.NewKVStoreService(appKeepers.keys[ibctransfertypes.StoreKey]),
		appKeepers.GetSubspace(ibctransfertypes.ModuleName),
		// The ICS4Wrapper is replaced by the PacketForwardKeeper instead of the channel so that sending can be overridden by the middleware
		appKeepers.PacketForwardKeeper,
		appKeepers.IBCKeeper.ChannelKeeper,
		bApp.MsgServiceRouter(),
		appKeepers.AccountKeeper,
		appKeepers.BankKeeper,
		govModAddress,
	)
	appKeepers.TransferKeeper = &transferKeeper

	appKeepers.PacketForwardKeeper.SetTransferKeeper(appKeepers.TransferKeeper)

	icaHostKeeper := icahostkeeper.NewKeeper(
		appCodec,
		runtime.NewKVStoreService(appKeepers.keys[icahosttypes.StoreKey]),
		appKeepers.GetSubspace(icahosttypes.SubModuleName),
		appKeepers.HooksICS4Wrapper,
		appKeepers.IBCKeeper.ChannelKeeper,
		appKeepers.AccountKeeper,
		bApp.MsgServiceRouter(),
		bApp.GRPCQueryRouter(),
		govModAddress,
	)
	appKeepers.ICAHostKeeper = &icaHostKeeper

	icaControllerKeeper := icacontrollerkeeper.NewKeeper(
		appCodec,
		runtime.NewKVStoreService(appKeepers.keys[icacontrollertypes.StoreKey]),
		appKeepers.GetSubspace(icacontrollertypes.SubModuleName),
		appKeepers.HooksICS4Wrapper,
		appKeepers.IBCKeeper.ChannelKeeper,
		bApp.MsgServiceRouter(),
		govModAddress,
	)
	appKeepers.ICAControllerKeeper = &icaControllerKeeper

	// Create Transfer Stack
	var transferStack porttypes.IBCModule
	transferStack = transfer.NewIBCModule(*appKeepers.TransferKeeper)
	transferStack = ibchooks.NewIBCMiddleware(transferStack, &appKeepers.HooksICS4Wrapper)
	transferStack = packetforward.NewIBCMiddleware(
		transferStack,
		appKeepers.PacketForwardKeeper,
		0,
		packetforwardkeeper.DefaultForwardTransferPacketTimeoutTimestamp,
	)
	// Since packetforward is outermost middleware, the ICS4Wrapper should be the innermost (base)
	// So we pass the callback-enabled wrapper (HooksICS4Wrapper) via WithICS4Wrapper
	appKeepers.TransferKeeper.WithICS4Wrapper(appKeepers.HooksICS4Wrapper)

	// create evidence keeper with router
	evidenceKeeper := evidencekeeper.NewKeeper(
		appCodec,
		runtime.NewKVStoreService(appKeepers.keys[evidencetypes.StoreKey]),
		appKeepers.StakingKeeper,
		appKeepers.SlashingKeeper,
		addresscodec.NewBech32Codec(sdk.Bech32PrefixAccAddr),
		runtime.ProvideCometInfoService(),
	)
	// If evidence needs to be handled for the app, set routes in router here and seal
	appKeepers.EvidenceKeeper = evidenceKeeper

	tfKeeper := tokenfactorykeeper.NewKeeper(
		appKeepers.keys[tokenfactorytypes.StoreKey],
		appKeepers.GetSubspace(tokenfactorytypes.ModuleName),
		maccPerms,
		appKeepers.AccountKeeper,
		appKeepers.BankKeeper,
		appKeepers.DistrKeeper,
	)
	appKeepers.TokenFactoryKeeper = &tfKeeper

	wasmConfig, err := wasm.ReadNodeConfig(appOpts)
	if err != nil {
		panic(fmt.Sprintf("error while reading wasm config: %s", err))
	}

	// custom messages for cosmwasm go here
	// registry := terpwasm.NewEncoderRegistry()
	// registry.RegisterEncoder(terpwasm.DistributionRoute, terpwasm.CustomDistributionEncoder)

	// Stargate Queries
	acceptedStargateQueries := AcceptedQueries()

	wasmOpts = append(wasmOpts,
		// wasmkeeper.WithMessageEncoders(terpwasm.MessageEncoders(registry)),
		wasmkeeper.WithQueryPlugins(
			&wasmkeeper.QueryPlugins{
				Stargate: wasmkeeper.AcceptListStargateQuerier(acceptedStargateQueries, bApp.GRPCQueryRouter(), appCodec),
			}),
	)

	wasmCapabilities := append(wasmkeeper.BuiltInCapabilities(), "cosmwasm_3_0")
	// create wasmvm to use for both x/wasm and wasm-light-client
	wasmVm, err := wasmvm.NewVM(wasmDir, wasmCapabilities, 32, wasmConfig.ContractDebugMode, wasmConfig.MemoryCacheSize)
	if err != nil {
		panic(fmt.Sprintf("failed to create terp wasm vm: %s", err))
	}

	lcWasmer, err := wasmvm.NewVM(ibcWasmConfig.DataDir, wasmCapabilities, 32, ibcWasmConfig.ContractDebugMode, wasmConfig.MemoryCacheSize)
	if err != nil {
		panic(fmt.Sprintf("failed to create terp wasm vm for 08-wasm: %s", err))
	}

	wasmKeeper := wasmkeeper.NewKeeper(
		appCodec,
		runtime.NewKVStoreService(appKeepers.keys[wasmtypes.StoreKey]),
		appKeepers.AccountKeeper,
		appKeepers.BankKeeper,
		appKeepers.StakingKeeper,
		distrkeeper.NewQuerier(*appKeepers.DistrKeeper),
		appKeepers.IBCKeeper.ChannelKeeper,
		appKeepers.IBCKeeper.ChannelKeeper,
		appKeepers.IBCKeeper.ChannelKeeperV2,
		appKeepers.TransferKeeper,
		bApp.MsgServiceRouter(),
		bApp.GRPCQueryRouter(),
		wasmDir,
		wasmConfig,
		wasmtypes.VMConfig{},
		wasmCapabilities,
		govModAddress,
		append(wasmOpts, wasmkeeper.WithWasmEngine(wasmVm))...,
	)
	appKeepers.WasmKeeper = &wasmKeeper

	// register CosmWasm authenticator
	appKeepers.AuthenticatorManager.RegisterAuthenticator(
		authenticator.NewCosmwasmAuthenticator(appKeepers.ContractKeeper, appKeepers.AccountKeeper, appCodec))

	ibcWasmClientKeeper := ibcwlckeeper.NewKeeperWithVM(
		appCodec,
		runtime.NewKVStoreService(appKeepers.keys[ibcwlctypes.StoreKey]),
		appKeepers.IBCKeeper.ClientKeeper,
		govModAddress,
		lcWasmer,
		bApp.GRPCQueryRouter(),
	)
	appKeepers.IBCWasmClientKeeper = &ibcWasmClientKeeper

	// set the contract keeper for the Ics20WasmHooks
	appKeepers.ContractKeeper = wasmkeeper.NewDefaultPermissionKeeper(appKeepers.WasmKeeper)
	appKeepers.Ics20WasmHooks.ContractKeeper = appKeepers.WasmKeeper

	feeshareKeeper := feesharekeeper.NewKeeper(
		appKeepers.keys[feesharetypes.StoreKey],
		appCodec,
		appKeepers.BankKeeper,
		appKeepers.WasmKeeper,
		appKeepers.AccountKeeper,
		authtypes.FeeCollectorName,
		govModAddress,
	)
	appKeepers.FeeShareKeeper = &feeshareKeeper

	globalFeeKeeper := globalfeekeeper.NewKeeper(
		appCodec,
		appKeepers.keys[globalfeetypes.StoreKey],
		govModAddress,
	)
	appKeepers.GlobalFeeKeeper = &globalFeeKeeper

	appKeepers.DripKeeper = dripkeeper.NewKeeper(
		appKeepers.keys[driptypes.StoreKey],
		appCodec,
		appKeepers.BankKeeper,
		authtypes.FeeCollectorName,
		govModAddress,
	)

	// Set legacy router for backwards compatibility with gov v1beta1
	appKeepers.GovKeeper.SetLegacyRouter(govRouter)

	// Create Interchain Accounts Stack
	// SendPacket, since it is originating from the application to core IBC:
	// icaAuthModuleKeeper.SendTx -> icaController.SendPacket -> fee.SendPacket -> channel.SendPacket
	var icaControllerStack porttypes.IBCModule
	icaControllerStack = icacontroller.NewIBCMiddleware(*appKeepers.ICAControllerKeeper)

	// RecvPacket, message that originates from core IBC and goes down to app, the flow is:
	// channel.RecvPacket -> fee.OnRecvPacket -> icaHost.OnRecvPacket
	var icaHostStack porttypes.IBCModule
	icaHostStack = icahost.NewIBCModule(*appKeepers.ICAHostKeeper)

	// Create fee enabled wasm ibc Stack
	var wasmStack porttypes.IBCModule
	wasmStack = wasm.NewIBCHandler(appKeepers.WasmKeeper, appKeepers.IBCKeeper.ChannelKeeper, appKeepers.TransferKeeper, appKeepers.IBCKeeper.ChannelKeeper)

	// Create static IBC router, add app routes, then set and seal it
	ibcRouter := porttypes.NewRouter().
		AddRoute(ibctransfertypes.ModuleName, transferStack).
		AddRoute(wasmtypes.ModuleName, wasmStack).
		AddRoute(icacontrollertypes.SubModuleName, icaControllerStack).
		AddRoute(icahosttypes.SubModuleName, icaHostStack)
	appKeepers.IBCKeeper.SetRouter(ibcRouter)

	return appKeepers
}

// initParamsKeeper init params keeper and its subspaces
func initParamsKeeper(appCodec codec.BinaryCodec, legacyAmino *codec.LegacyAmino, key, tkey storetypes.StoreKey) paramskeeper.Keeper {
	paramsKeeper := paramskeeper.NewKeeper(appCodec, legacyAmino, key, tkey)

	keytable := ibcclienttypes.ParamKeyTable()
	keytable.RegisterParamSet(&ibcconnectiontypes.Params{})

	paramsKeeper.Subspace(authtypes.ModuleName)
	paramsKeeper.Subspace(banktypes.ModuleName)
	paramsKeeper.Subspace(stakingtypes.ModuleName) // Used for GlobalFee
	paramsKeeper.Subspace(minttypes.ModuleName)
	paramsKeeper.Subspace(distrtypes.ModuleName)
	paramsKeeper.Subspace(slashingtypes.ModuleName)
	paramsKeeper.Subspace(govtypes.ModuleName)
	paramsKeeper.Subspace(crisistypes.ModuleName)
	paramsKeeper.Subspace(ibctransfertypes.ModuleName).WithKeyTable(ibctransfertypes.ParamKeyTable())
	paramsKeeper.Subspace(ibcexported.ModuleName).WithKeyTable(keytable)
	paramsKeeper.Subspace(tokenfactorytypes.ModuleName)
	paramsKeeper.Subspace(icahosttypes.SubModuleName)
	paramsKeeper.Subspace(icacontrollertypes.SubModuleName)
	paramsKeeper.Subspace(packetforwardtypes.ModuleName)
	paramsKeeper.Subspace(globalfee.ModuleName)
	paramsKeeper.Subspace(ibchookstypes.ModuleName)
	paramsKeeper.Subspace(feesharetypes.ModuleName).WithKeyTable(feesharetypes.ParamKeyTable())
	paramsKeeper.Subspace(smartaccounttypes.ModuleName).WithKeyTable(smartaccounttypes.ParamKeyTable())
	paramsKeeper.Subspace(wasmtypes.ModuleName)

	return paramsKeeper
}

// GetSubspace returns a param subspace for a given module name.
//
// NOTE: This is solely to be used for testing purposes.
func (app *AppKeepers) GetSubspace(moduleName string) paramstypes.Subspace {
	subspace, _ := app.ParamsKeeper.GetSubspace(moduleName)
	return subspace
}

// GetStakingKeeper implements the TestingApp interface.
func (appKeepers *AppKeepers) GetStakingKeeper() *stakingkeeper.Keeper {
	return appKeepers.StakingKeeper
}

// GetIBCKeeper implements the TestingApp interface.
func (appKeepers *AppKeepers) GetIBCKeeper() *ibckeeper.Keeper {
	return appKeepers.IBCKeeper
}

// GetWasmKeeper implements the TestingApp interface.
func (appKeepers *AppKeepers) GetWasmKeeper() *wasmkeeper.Keeper {
	return appKeepers.WasmKeeper
}

// BlockedAddresses returns all the app's blocked account addresses.
func BlockedAddresses() map[string]bool {
	modAccAddrs := make(map[string]bool)
	for acc := range GetMaccPerms() {
		modAccAddrs[authtypes.NewModuleAddress(acc).String()] = true
	}

	// allow the following addresses to receive funds
	delete(modAccAddrs, authtypes.NewModuleAddress(govtypes.ModuleName).String())

	return modAccAddrs
}

// GetMaccPerms returns a copy of the module account permissions
//
// NOTE: This is solely to be used for testing purposes.
func GetMaccPerms() map[string][]string {
	dupMaccPerms := make(map[string][]string)
	for k, v := range maccPerms {
		dupMaccPerms[k] = v
	}

	return dupMaccPerms
}
