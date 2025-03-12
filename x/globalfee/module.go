package globalfee

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/gorilla/mux"
	"github.com/grpc-ecosystem/grpc-gateway/runtime"
	"github.com/spf13/cobra"

	"cosmossdk.io/core/appmodule"
	errorsmod "cosmossdk.io/errors"
	"github.com/cosmos/cosmos-sdk/client"
	"github.com/cosmos/cosmos-sdk/codec"
	codectypes "github.com/cosmos/cosmos-sdk/codec/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/module"
	simtypes "github.com/cosmos/cosmos-sdk/types/simulation"

	"github.com/terpnetwork/terp-core/v4/x/globalfee/client/cli"
	"github.com/terpnetwork/terp-core/v4/x/globalfee/keeper"
	"github.com/terpnetwork/terp-core/v4/x/globalfee/types"
)

var (
	_ module.AppModule           = AppModule{}
	_ module.AppModuleBasic      = AppModuleBasic{}
	_ module.AppModuleBasic      = (*AppModule)(nil)
	_ module.AppModuleSimulation = (*AppModule)(nil)
	_ module.HasGenesis          = (*AppModule)(nil)

	_ appmodule.AppModule       = (*AppModule)(nil)
	_ appmodule.HasBeginBlocker = (*AppModule)(nil)
	_ appmodule.HasEndBlocker   = (*AppModule)(nil)
)

// ConsensusVersion defines the current x/globalfee module consensus version.
const ConsensusVersion = 2

// AppModuleBasic defines the basic application module used by the wasm module.
type AppModuleBasic struct {
	cdc codec.Codec
}

func (a AppModuleBasic) Name() string {
	return types.ModuleName
}

func (a AppModuleBasic) DefaultGenesis(cdc codec.JSONCodec) json.RawMessage {
	return cdc.MustMarshalJSON(&types.GenesisState{
		Params: types.DefaultParams(),
	})
}

func (a AppModuleBasic) ValidateGenesis(marshaler codec.JSONCodec, _ client.TxEncodingConfig, message json.RawMessage) error {
	var data types.GenesisState
	err := marshaler.UnmarshalJSON(message, &data)
	if err != nil {
		return err
	}
	if err := data.Params.Validate(); err != nil {
		return errorsmod.Wrap(err, "params")
	}
	return nil
}

func (a AppModuleBasic) RegisterRESTRoutes(_ client.Context, _ *mux.Router) {
}

func (a AppModuleBasic) RegisterGRPCGatewayRoutes(clientCtx client.Context, mux *runtime.ServeMux) {
	err := types.RegisterQueryHandlerClient(context.Background(), mux, types.NewQueryClient(clientCtx))
	if err != nil {
		// same behavior as in cosmos-sdk
		panic(err)
	}
}

func (a AppModuleBasic) GetTxCmd() *cobra.Command {
	return nil
}

func (a AppModuleBasic) GetQueryCmd() *cobra.Command {
	return cli.GetQueryCmd()
}

func (AppModuleBasic) RegisterLegacyAminoCodec(cdc *codec.LegacyAmino) {
	types.RegisterLegacyAminoCodec(cdc)
}

func (a AppModuleBasic) RegisterInterfaces(r codectypes.InterfaceRegistry) {
	types.RegisterInterfaces(r)
}

type AppModule struct {
	AppModuleBasic

	keeper keeper.Keeper

	// bondDenom is used solely for migration off of x/params
	bondDenom string
}

// NewAppModule constructor
func NewAppModule(
	cdc codec.Codec,
	keeper keeper.Keeper,
	debondDenom string,
) *AppModule {
	return &AppModule{
		AppModuleBasic: AppModuleBasic{cdc: cdc},
		keeper:         keeper,
		bondDenom:      debondDenom,
	}
}

// IsAppModule implements the appmodule.AppModule interface.
func (am AppModule) IsAppModule() {}

// IsOnePerModuleType is a marker function just indicates that this is a one-per-module type.
func (am AppModule) IsOnePerModuleType() {}

func (a AppModule) InitGenesis(ctx sdk.Context, marshaler codec.JSONCodec, message json.RawMessage) {
	var genesisState types.GenesisState
	marshaler.MustUnmarshalJSON(message, &genesisState)
	// a.paramSpace.SetParamSet(ctx, &genesisState.Params)
	_ = a.keeper.SetParams(ctx, genesisState.Params) // note: we may want to have this function return an error in the future.
	return
}

func (a AppModule) ExportGenesis(ctx sdk.Context, marshaler codec.JSONCodec) json.RawMessage {
	params := a.keeper.GetParams(ctx)
	genState := types.NewGenesisState(params)
	return marshaler.MustMarshalJSON(genState)
}

func (a AppModule) RegisterInvariants(_ sdk.InvariantRegistry) {
}

func (a AppModule) QuerierRoute() string {
	return types.QuerierRoute
}

func (a AppModule) RegisterServices(cfg module.Configurator) {
	types.RegisterQueryServer(cfg.QueryServer(), NewGrpcQuerier(a.keeper))

	m := keeper.NewMigrator(a.keeper, a.bondDenom)
	if err := cfg.RegisterMigration(types.ModuleName, 1, m.Migrate1to2); err != nil {
		panic(fmt.Sprintf("failed to migrate x/%s from version 1 to 2: %v", types.ModuleName, err))
	}
}

func (a AppModule) BeginBlock(_ context.Context) error {
	return nil
}

func (a AppModule) EndBlock(_ context.Context) error {
	return nil
}

// ConsensusVersion is a sequence number for state-breaking change of the
// module. It should be incremented on each consensus-breaking change
// introduced by the module. To avoid wrong/empty versions, the initial version
// should be set to 1.
func (a AppModule) ConsensusVersion() uint64 {
	return ConsensusVersion
}

// GenerateGenesisState creates a randomized GenState of the valset module.
func (am AppModule) SimulatorGenesisState(simState *module.SimulationState) {
	ftDefaultGen := types.DefaultGenesisState()
	ftDefaultGenJson := simState.Cdc.MustMarshalJSON(ftDefaultGen)
	simState.GenState[types.ModuleName] = ftDefaultGenJson
}

// GenerateGenesisState creates a randomized GenState of the fees module.
func (am AppModule) GenerateGenesisState(_ *module.SimulationState) {
}

// RegisterStoreDecoder registers a decoder for fees module's types.
func (am AppModule) RegisterStoreDecoder(_ simtypes.StoreDecoderRegistry) {
}

// WeightedOperations doesn't return any mint module operation.
func (AppModule) WeightedOperations(_ module.SimulationState) []simtypes.WeightedOperation {
	return nil
}
