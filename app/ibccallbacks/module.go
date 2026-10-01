package ibccallbacks

import (
	"encoding/json"

	"github.com/gorilla/mux"
	"github.com/grpc-ecosystem/grpc-gateway/runtime"
	"github.com/spf13/cobra"

	"cosmossdk.io/core/appmodule"

	"github.com/cosmos/cosmos-sdk/client"
	"github.com/cosmos/cosmos-sdk/codec"
	cdctypes "github.com/cosmos/cosmos-sdk/codec/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/module"
	ibccallbackstypes "github.com/cosmos/ibc-go/v11/modules/apps/callbacks/types"
)

var (
	_ module.AppModuleBasic = AppModuleBasic{}
	_ module.AppModule      = AppModule{}
	_ module.HasGenesis     = AppModule{}
	_ appmodule.AppModule   = AppModule{}
)

// AppModuleBasic is the stateless callbacks module. Packet callbacks live on
// the IBC middleware. This module exists so an upgrade can add it with an
// empty genesis and drop the old hooks store.
type AppModuleBasic struct{}

func (AppModuleBasic) Name() string { return ibccallbackstypes.ModuleName }

func (AppModuleBasic) RegisterLegacyAminoCodec(*codec.LegacyAmino) {}

func (AppModuleBasic) RegisterInterfaces(cdctypes.InterfaceRegistry) {}

func (AppModuleBasic) DefaultGenesis(codec.JSONCodec) json.RawMessage {
	return []byte("{}")
}

func (AppModuleBasic) ValidateGenesis(codec.JSONCodec, client.TxEncodingConfig, json.RawMessage) error {
	return nil
}

func (AppModuleBasic) RegisterRESTRoutes(client.Context, *mux.Router) {}

func (AppModuleBasic) RegisterGRPCGatewayRoutes(client.Context, *runtime.ServeMux) {}

func (AppModuleBasic) GetTxCmd() *cobra.Command { return nil }

func (AppModuleBasic) GetQueryCmd() *cobra.Command { return nil }

type AppModule struct {
	AppModuleBasic
}

func NewAppModule() AppModule { return AppModule{} }

func (AppModule) IsAppModule() {}

func (AppModule) IsOnePerModuleType() {}

func (AppModule) ConsensusVersion() uint64 { return 1 }

func (AppModule) RegisterInvariants(sdk.InvariantRegistry) {}

func (AppModule) RegisterServices(module.Configurator) {}

func (AppModule) InitGenesis(sdk.Context, codec.JSONCodec, json.RawMessage) {}

func (AppModule) ExportGenesis(sdk.Context, codec.JSONCodec) json.RawMessage {
	return []byte("{}")
}
