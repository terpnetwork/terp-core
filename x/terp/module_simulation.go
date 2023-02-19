package terp

import (
	"math/rand"

	"github.com/cosmos/cosmos-sdk/baseapp"
	simappparams "github.com/cosmos/cosmos-sdk/simapp/params"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/module"
	simtypes "github.com/cosmos/cosmos-sdk/types/simulation"
	"github.com/cosmos/cosmos-sdk/x/simulation"
	"github.com/terpnetwork/terp-core/testutil/sample"
	terpsimulation "github.com/terpnetwork/terp-core/x/terp/simulation"
	"github.com/terpnetwork/terp-core/x/terp/types"
)

// avoid unused import issue
var (
	_ = sample.AccAddress
	_ = terpsimulation.FindAccount
	_ = simappparams.StakePerAccount
	_ = simulation.MsgEntryKind
	_ = baseapp.Paramspace
)

const (
	opWeightMsgCreateTerpid = "op_weight_msg_terpid"
	// TODO: Determine the simulation weight value
	defaultWeightMsgCreateTerpid int = 100

	opWeightMsgUpdateTerpid = "op_weight_msg_terpid"
	// TODO: Determine the simulation weight value
	defaultWeightMsgUpdateTerpid int = 100

	opWeightMsgDeleteTerpid = "op_weight_msg_terpid"
	// TODO: Determine the simulation weight value
	defaultWeightMsgDeleteTerpid int = 100

	opWeightMsgCreateSupplychain = "op_weight_msg_supplychain"
	// TODO: Determine the simulation weight value
	defaultWeightMsgCreateSupplychain int = 100

	opWeightMsgUpdateSupplychain = "op_weight_msg_supplychain"
	// TODO: Determine the simulation weight value
	defaultWeightMsgUpdateSupplychain int = 100

	opWeightMsgDeleteSupplychain = "op_weight_msg_supplychain"
	// TODO: Determine the simulation weight value
	defaultWeightMsgDeleteSupplychain int = 100

	// this line is used by starport scaffolding # simapp/module/const
)

// GenerateGenesisState creates a randomized GenState of the module
func (AppModule) GenerateGenesisState(simState *module.SimulationState) {
	accs := make([]string, len(simState.Accounts))
	for i, acc := range simState.Accounts {
		accs[i] = acc.Address.String()
	}
	terpGenesis := types.GenesisState{
		Params: types.DefaultParams(),
		TerpidList: []types.Terpid{
			{
				Id:      0,
				Creator: sample.AccAddress(),
			},
			{
				Id:      1,
				Creator: sample.AccAddress(),
			},
		},
		TerpidCount: 2,
		SupplychainList: []types.Supplychain{
			{
				Id:      0,
				Creator: sample.AccAddress(),
			},
			{
				Id:      1,
				Creator: sample.AccAddress(),
			},
		},
		SupplychainCount: 2,
		// this line is used by starport scaffolding # simapp/module/genesisState
	}
	simState.GenState[types.ModuleName] = simState.Cdc.MustMarshalJSON(&terpGenesis)
}

// ProposalContents doesn't return any content functions for governance proposals
func (AppModule) ProposalContents(_ module.SimulationState) []simtypes.WeightedProposalContent {
	return nil
}

// RandomizedParams creates randomized  param changes for the simulator
func (am AppModule) RandomizedParams(_ *rand.Rand) []simtypes.ParamChange {
	return []simtypes.ParamChange{}
}

// RegisterStoreDecoder registers a decoder
func (am AppModule) RegisterStoreDecoder(_ sdk.StoreDecoderRegistry) {}

// WeightedOperations returns the all the gov module operations with their respective weights.
func (am AppModule) WeightedOperations(simState module.SimulationState) []simtypes.WeightedOperation {
	operations := make([]simtypes.WeightedOperation, 0)

	var weightMsgCreateTerpid int
	simState.AppParams.GetOrGenerate(simState.Cdc, opWeightMsgCreateTerpid, &weightMsgCreateTerpid, nil,
		func(_ *rand.Rand) {
			weightMsgCreateTerpid = defaultWeightMsgCreateTerpid
		},
	)
	operations = append(operations, simulation.NewWeightedOperation(
		weightMsgCreateTerpid,
		terpsimulation.SimulateMsgCreateTerpid(am.accountKeeper, am.bankKeeper, am.keeper),
	))

	var weightMsgUpdateTerpid int
	simState.AppParams.GetOrGenerate(simState.Cdc, opWeightMsgUpdateTerpid, &weightMsgUpdateTerpid, nil,
		func(_ *rand.Rand) {
			weightMsgUpdateTerpid = defaultWeightMsgUpdateTerpid
		},
	)
	operations = append(operations, simulation.NewWeightedOperation(
		weightMsgUpdateTerpid,
		terpsimulation.SimulateMsgUpdateTerpid(am.accountKeeper, am.bankKeeper, am.keeper),
	))

	var weightMsgDeleteTerpid int
	simState.AppParams.GetOrGenerate(simState.Cdc, opWeightMsgDeleteTerpid, &weightMsgDeleteTerpid, nil,
		func(_ *rand.Rand) {
			weightMsgDeleteTerpid = defaultWeightMsgDeleteTerpid
		},
	)
	operations = append(operations, simulation.NewWeightedOperation(
		weightMsgDeleteTerpid,
		terpsimulation.SimulateMsgDeleteTerpid(am.accountKeeper, am.bankKeeper, am.keeper),
	))

	var weightMsgCreateSupplychain int
	simState.AppParams.GetOrGenerate(simState.Cdc, opWeightMsgCreateSupplychain, &weightMsgCreateSupplychain, nil,
		func(_ *rand.Rand) {
			weightMsgCreateSupplychain = defaultWeightMsgCreateSupplychain
		},
	)
	operations = append(operations, simulation.NewWeightedOperation(
		weightMsgCreateSupplychain,
		terpsimulation.SimulateMsgCreateSupplychain(am.accountKeeper, am.bankKeeper, am.keeper),
	))

	var weightMsgUpdateSupplychain int
	simState.AppParams.GetOrGenerate(simState.Cdc, opWeightMsgUpdateSupplychain, &weightMsgUpdateSupplychain, nil,
		func(_ *rand.Rand) {
			weightMsgUpdateSupplychain = defaultWeightMsgUpdateSupplychain
		},
	)
	operations = append(operations, simulation.NewWeightedOperation(
		weightMsgUpdateSupplychain,
		terpsimulation.SimulateMsgUpdateSupplychain(am.accountKeeper, am.bankKeeper, am.keeper),
	))

	var weightMsgDeleteSupplychain int
	simState.AppParams.GetOrGenerate(simState.Cdc, opWeightMsgDeleteSupplychain, &weightMsgDeleteSupplychain, nil,
		func(_ *rand.Rand) {
			weightMsgDeleteSupplychain = defaultWeightMsgDeleteSupplychain
		},
	)
	operations = append(operations, simulation.NewWeightedOperation(
		weightMsgDeleteSupplychain,
		terpsimulation.SimulateMsgDeleteSupplychain(am.accountKeeper, am.bankKeeper, am.keeper),
	))

	// this line is used by starport scaffolding # simapp/module/operation

	return operations
}
