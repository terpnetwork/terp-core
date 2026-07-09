package hashmerchant

import (
	"context"
	"encoding/json"
	"fmt"

	"cosmossdk.io/core/appmodule"
	"github.com/grpc-ecosystem/grpc-gateway/runtime"
	"github.com/spf13/cobra"

	"github.com/cosmos/cosmos-sdk/client"
	"github.com/cosmos/cosmos-sdk/codec"
	codectypes "github.com/cosmos/cosmos-sdk/codec/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/module"

	"github.com/terpnetwork/terp-core/v5/x/hashmerchant/client/cli"
	"github.com/terpnetwork/terp-core/v5/x/hashmerchant/keeper"
	"github.com/terpnetwork/terp-core/v5/x/hashmerchant/types"
)

var (
	_ module.AppModule      = AppModule{}
	_ module.AppModuleBasic = AppModuleBasic{}
	_ module.HasGenesis     = (*AppModule)(nil)

	_ appmodule.AppModule     = (*AppModule)(nil)
	_ appmodule.HasEndBlocker = (*AppModule)(nil)
)

const ConsensusVersion = 1

// ---------------------------------------------------------------------------
// AppModuleBasic
// ---------------------------------------------------------------------------

type AppModuleBasic struct{}

func NewAppModuleBasic() AppModuleBasic { return AppModuleBasic{} }

func (AppModuleBasic) Name() string { return types.ModuleName }

func (AppModuleBasic) RegisterLegacyAminoCodec(cdc *codec.LegacyAmino) {
	types.RegisterLegacyAminoCodec(cdc)
}

func (AppModuleBasic) RegisterInterfaces(reg codectypes.InterfaceRegistry) {
	types.RegisterInterfaces(reg)
}

func (AppModuleBasic) DefaultGenesis(cdc codec.JSONCodec) json.RawMessage {
	return cdc.MustMarshalJSON(types.DefaultGenesis())
}

func (AppModuleBasic) ValidateGenesis(cdc codec.JSONCodec, _ client.TxEncodingConfig, bz json.RawMessage) error {
	var gs types.GenesisState
	if err := cdc.UnmarshalJSON(bz, &gs); err != nil {
		return fmt.Errorf("failed to unmarshal %s genesis state: %w", types.ModuleName, err)
	}
	return gs.Validate()
}

func (AppModuleBasic) RegisterGRPCGatewayRoutes(clientCtx client.Context, mux *runtime.ServeMux) {
	_ = types.RegisterQueryHandlerClient(context.Background(), mux, types.NewQueryClient(clientCtx))
}

func (AppModuleBasic) GetTxCmd() *cobra.Command {
	return cli.GetTxCmd()
}

func (AppModuleBasic) GetQueryCmd() *cobra.Command {
	return cli.GetQueryCmd()
}

// ---------------------------------------------------------------------------
// AppModule
// ---------------------------------------------------------------------------

type AppModule struct {
	AppModuleBasic
	keeper *keeper.Keeper
}

func NewAppModule(k *keeper.Keeper) AppModule {
	return AppModule{
		AppModuleBasic: NewAppModuleBasic(),
		keeper:         k,
	}
}

func (am AppModule) Name() string               { return am.AppModuleBasic.Name() }
func (am AppModule) IsAppModule()                {}
func (am AppModule) IsOnePerModuleType()         {}
func (AppModule) QuerierRoute() string           { return types.QuerierRoute }
func (AppModule) ConsensusVersion() uint64       { return ConsensusVersion }

func (am AppModule) RegisterServices(cfg module.Configurator) {
	types.RegisterMsgServer(cfg.MsgServer(), keeper.NewMsgServerImpl(*am.keeper))
	types.RegisterQueryServer(cfg.QueryServer(), *am.keeper)
}

func (am AppModule) RegisterInvariants(_ sdk.InvariantRegistry) {}

func (am AppModule) InitGenesis(ctx sdk.Context, cdc codec.JSONCodec, gs json.RawMessage) {
	var genState types.GenesisState
	cdc.MustUnmarshalJSON(gs, &genState)
	am.keeper.InitGenesis(ctx, genState)
}

func (am AppModule) ExportGenesis(ctx sdk.Context, cdc codec.JSONCodec) json.RawMessage {
	genState := am.keeper.ExportGenesis(ctx)
	return cdc.MustMarshalJSON(genState)
}

func (am AppModule) EndBlock(ctx context.Context) error {
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	return am.keeper.EndBlocker(sdkCtx)
}
