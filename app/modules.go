package app

import (
	wasm "github.com/CosmWasm/wasmd/x/wasm"
	wasmtypes "github.com/CosmWasm/wasmd/x/wasm/types"
	"github.com/cosmos/cosmos-sdk/client"
	mint "github.com/cosmos/cosmos-sdk/x/mint"
	minttypes "github.com/cosmos/cosmos-sdk/x/mint/types"
	ica "github.com/cosmos/ibc-go/v11/modules/apps/27-interchain-accounts"
	icatypes "github.com/cosmos/ibc-go/v11/modules/apps/27-interchain-accounts/types"
	packetforward "github.com/cosmos/ibc-go/v11/modules/apps/packet-forward-middleware"
	packetforwardtypes "github.com/cosmos/ibc-go/v11/modules/apps/packet-forward-middleware/types"
	transfer "github.com/cosmos/ibc-go/v11/modules/apps/transfer"
	ibctransfertypes "github.com/cosmos/ibc-go/v11/modules/apps/transfer/types"
	ibc "github.com/cosmos/ibc-go/v11/modules/core"
	ibcexported "github.com/cosmos/ibc-go/v11/modules/core/exported"
	ibctm "github.com/cosmos/ibc-go/v11/modules/light-clients/07-tendermint"

	"github.com/cosmos/cosmos-sdk/contrib/x/crisis"
	crisistypes "github.com/cosmos/cosmos-sdk/contrib/x/crisis/types"
	"github.com/cosmos/cosmos-sdk/types/module"
	"github.com/cosmos/cosmos-sdk/x/auth"
	authsims "github.com/cosmos/cosmos-sdk/x/auth/simulation"
	authtypes "github.com/cosmos/cosmos-sdk/x/auth/types"
	"github.com/cosmos/cosmos-sdk/x/auth/vesting"
	vestingtypes "github.com/cosmos/cosmos-sdk/x/auth/vesting/types"
	"github.com/cosmos/cosmos-sdk/x/authz"
	authzmodule "github.com/cosmos/cosmos-sdk/x/authz/module"
	"github.com/cosmos/cosmos-sdk/x/bank"
	banktypes "github.com/cosmos/cosmos-sdk/x/bank/types"
	"github.com/cosmos/cosmos-sdk/x/consensus"
	consensusparamtypes "github.com/cosmos/cosmos-sdk/x/consensus/types"
	distr "github.com/cosmos/cosmos-sdk/x/distribution"
	distrtypes "github.com/cosmos/cosmos-sdk/x/distribution/types"
	"github.com/cosmos/cosmos-sdk/x/evidence"
	evidencetypes "github.com/cosmos/cosmos-sdk/x/evidence/types"
	"github.com/cosmos/cosmos-sdk/x/feegrant"
	feegrantmodule "github.com/cosmos/cosmos-sdk/x/feegrant/module"
	"github.com/cosmos/cosmos-sdk/x/genutil"
	genutiltypes "github.com/cosmos/cosmos-sdk/x/genutil/types"
	"github.com/cosmos/cosmos-sdk/x/gov"
	govtypes "github.com/cosmos/cosmos-sdk/x/gov/types"

	"github.com/cosmos/cosmos-sdk/x/slashing"
	slashingtypes "github.com/cosmos/cosmos-sdk/x/slashing/types"
	"github.com/cosmos/cosmos-sdk/x/staking"
	stakingtypes "github.com/cosmos/cosmos-sdk/x/staking/types"
	"github.com/cosmos/cosmos-sdk/x/upgrade"
	upgradetypes "github.com/cosmos/cosmos-sdk/x/upgrade/types"

	appparams "github.com/terpnetwork/terp-core/v6/app/params"
	"github.com/terpnetwork/terp-core/v6/x/feeshare"
	feesharetypes "github.com/terpnetwork/terp-core/v6/x/feeshare/types"
	"github.com/terpnetwork/terp-core/v6/x/globalfee"
	"github.com/terpnetwork/terp-core/v6/x/tokenfactory"

	"github.com/terpnetwork/terp-core/v6/x/drip"
	driptypes "github.com/terpnetwork/terp-core/v6/x/drip/types"

	"github.com/terpnetwork/terp-core/v6/x/hashmerchant"
	hashmerchanttypes "github.com/terpnetwork/terp-core/v6/x/hashmerchant/types"

	cwhooksmodule "github.com/terpnetwork/terp-core/v6/x/cw-hooks/module"
	cwhookstypes "github.com/terpnetwork/terp-core/v6/x/cw-hooks/types"

	ibchooks "github.com/cosmos/ibc-apps/modules/ibc-hooks/v11"
	ibchookstypes "github.com/cosmos/ibc-apps/modules/ibc-hooks/v11/types"

	// cwhooks "github.com/terpnetwork/terp-core/v6/x/cw-hooks"
	govclient "github.com/cosmos/cosmos-sdk/x/gov/client"

	tokenfactorytypes "github.com/terpnetwork/terp-core/v6/x/tokenfactory/types"

	smartaccount "github.com/terpnetwork/terp-core/v6/x/smart-account"
	smartaccounttypes "github.com/terpnetwork/terp-core/v6/x/smart-account/types"

	wasmlc "github.com/cosmos/ibc-go/modules/light-clients/08-wasm/v11"
	wasmlctypes "github.com/cosmos/ibc-go/modules/light-clients/08-wasm/v11/types"
)

// ModuleBasics defines the module BasicManager is in charge of setting up basic,
// non-dependant module elements, such as codec registration
// and genesis verification.
var ModuleBasics = module.NewBasicManager(
	auth.AppModuleBasic{},
	genutil.NewAppModuleBasic(genutiltypes.DefaultMessageValidator),
	bank.AppModuleBasic{},
	staking.AppModuleBasic{},
	mint.AppModuleBasic{},
	distr.AppModuleBasic{},
	gov.NewAppModuleBasic([]govclient.ProposalHandler{}),
	crisis.AppModuleBasic{},
	slashing.AppModuleBasic{},
	feegrantmodule.AppModuleBasic{},
	upgrade.AppModuleBasic{},
	evidence.AppModuleBasic{},
	authzmodule.AppModuleBasic{},
	vesting.AppModuleBasic{},

	consensus.AppModuleBasic{},
	// non sdk modules
	wasm.AppModuleBasic{},
	ibc.AppModuleBasic{},
	wasmlc.AppModuleBasic{},
	ibctm.AppModuleBasic{},
	transfer.AppModuleBasic{},
	ica.AppModuleBasic{},
	ibchooks.AppModuleBasic{},
	packetforward.AppModuleBasic{},
	feeshare.AppModuleBasic{},
	globalfee.AppModuleBasic{},
	drip.AppModuleBasic{},
	tokenfactory.AppModuleBasic{},
	smartaccount.AppModuleBasic{},
	hashmerchant.AppModuleBasic{},
	cwhooksmodule.AppModuleBasic{},
)

func simulationModules(
	app *TerpApp,
	encodingConfig appparams.EncodingConfig,
	_ bool,
) []module.AppModuleSimulation {
	appCodec := encodingConfig.Marshaler

	bondDenom := app.GetChainBondDenom()

	return []module.AppModuleSimulation{
		auth.NewAppModule(appCodec, *app.AccountKeeper, authsims.RandomGenesisAccounts),
		bank.NewAppModule(appCodec, app.BankKeeper, app.AccountKeeper),
		feegrantmodule.NewAppModule(appCodec, app.AccountKeeper, app.BankKeeper, *app.FeeGrantKeeper, app.interfaceRegistry),
		authzmodule.NewAppModule(appCodec, *app.AuthzKeeper, app.AccountKeeper, app.BankKeeper, app.interfaceRegistry),
		gov.NewAppModule(appCodec, app.GovKeeper, app.AccountKeeper, app.BankKeeper),
		mint.NewAppModule(appCodec, *app.MintKeeper, app.AccountKeeper, nil),
		staking.NewAppModule(appCodec, app.StakingKeeper, app.AccountKeeper, app.BankKeeper),
		distr.NewAppModule(appCodec, *app.DistrKeeper, app.AccountKeeper, app.BankKeeper, app.StakingKeeper),
		slashing.NewAppModule(appCodec, *app.SlashingKeeper, app.AccountKeeper, app.BankKeeper, app.StakingKeeper, app.interfaceRegistry),
		evidence.NewAppModule(*app.EvidenceKeeper),
		wasm.NewAppModule(appCodec, app.WasmKeeper, app.StakingKeeper, app.AccountKeeper, app.BankKeeper, app.MsgServiceRouter()),
		ibc.NewAppModule(app.IBCKeeper),
		transfer.NewAppModule(app.TransferKeeper),
		feeshare.NewAppModule(app.FeeShareKeeper, *app.AccountKeeper),
		drip.NewAppModule(app.DripKeeper, *app.AccountKeeper),
		globalfee.NewAppModule(appCodec, app.GlobalFeeKeeper, bondDenom),
		// wasmlc.NewAppModule(*app.IBCWasmClientKeeper),
		smartaccount.NewAppModule(appCodec, *app.SmartAccountKeeper),
	}
}

func orderBeginBlockers() []string {
	return []string{
		upgradetypes.ModuleName,
		minttypes.ModuleName,
		distrtypes.ModuleName,
		slashingtypes.ModuleName,
		evidencetypes.ModuleName,
		stakingtypes.ModuleName,
		authtypes.ModuleName,
		banktypes.ModuleName,
		govtypes.ModuleName,
		crisistypes.ModuleName,
		genutiltypes.ModuleName,
		authz.ModuleName,
		feegrant.ModuleName,
		vestingtypes.ModuleName,
		consensusparamtypes.ModuleName,
		// additional non simd modules
		ibctransfertypes.ModuleName,
		ibcexported.ModuleName,
		icatypes.ModuleName,
		packetforwardtypes.ModuleName,
		driptypes.ModuleName,
		feesharetypes.ModuleName,
		globalfee.ModuleName,
		ibchookstypes.ModuleName,
		tokenfactorytypes.ModuleName,
		cwhookstypes.ModuleName,
		hashmerchanttypes.ModuleName,
		wasmtypes.ModuleName,
		wasmlctypes.ModuleName,
	}
}

func orderEndBlockers() []string {
	return []string{
		banktypes.ModuleName,
		crisistypes.ModuleName,
		govtypes.ModuleName,
		stakingtypes.ModuleName,
		authtypes.ModuleName,
		distrtypes.ModuleName,
		slashingtypes.ModuleName,
		minttypes.ModuleName,
		genutiltypes.ModuleName,
		evidencetypes.ModuleName,
		authz.ModuleName,
		feegrant.ModuleName,
		upgradetypes.ModuleName,
		vestingtypes.ModuleName,
		consensusparamtypes.ModuleName,
		// additional non simd modules
		ibctransfertypes.ModuleName,
		ibcexported.ModuleName,
		icatypes.ModuleName,
		packetforwardtypes.ModuleName,
		driptypes.ModuleName,
		feesharetypes.ModuleName,
		globalfee.ModuleName,
		ibchookstypes.ModuleName,
		tokenfactorytypes.ModuleName,
		smartaccounttypes.ModuleName,
		hashmerchanttypes.ModuleName,
		cwhookstypes.ModuleName,
		wasmtypes.ModuleName,
		wasmlctypes.ModuleName,
	}
}

func orderInitBlockers() []string {
	return []string{
		authtypes.ModuleName, banktypes.ModuleName,
		distrtypes.ModuleName, stakingtypes.ModuleName, slashingtypes.ModuleName, govtypes.ModuleName,
		minttypes.ModuleName, crisistypes.ModuleName, genutiltypes.ModuleName, evidencetypes.ModuleName, authz.ModuleName,
		feegrant.ModuleName, upgradetypes.ModuleName,
		vestingtypes.ModuleName, consensusparamtypes.ModuleName,
		// additional non simd modules
		ibctransfertypes.ModuleName,
		ibcexported.ModuleName,
		icatypes.ModuleName,
		// wasm after ibc transfer
		driptypes.ModuleName,
		feesharetypes.ModuleName,
		globalfee.ModuleName,
		packetforwardtypes.ModuleName,
		ibchookstypes.ModuleName,
		tokenfactorytypes.ModuleName,
		smartaccounttypes.ModuleName,
		hashmerchanttypes.ModuleName,
		cwhookstypes.ModuleName,
		wasmtypes.ModuleName,
		wasmlctypes.ModuleName,
	}
}

func (app *TerpApp) GetTxConfig() client.TxConfig {
	return GetEncodingConfig().TxConfig
}
