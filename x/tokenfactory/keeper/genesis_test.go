package keeper_test

import (
	sdk "github.com/cosmos/cosmos-sdk/types"
	banktypes "github.com/cosmos/cosmos-sdk/x/bank/types"

	"github.com/terpnetwork/terp-core/v2/x/tokenfactory/types"
)

func (suite *KeeperTestSuite) TestGenesis() {
	genesisState := types.GenesisState{
		FactoryDenoms: []types.GenesisDenom{
			{
				Denom: "factory/terp1t7egva48prqmzl59x5ngv4zx0dtrwewc22y7f5/bitcoin",
				AuthorityMetadata: types.DenomAuthorityMetadata{
					Admin: "terp1t7egva48prqmzl59x5ngv4zx0dtrwewc22y7f5",
				},
			},
			{
				Denom: "factory/terp1t7egva48prqmzl59x5ngv4zx0dtrwewc22y7f5/diff-admin",
				AuthorityMetadata: types.DenomAuthorityMetadata{
					Admin: "terp15czt5nhlnvayqq37xun9s9yus0d6y26dp5u07j",
				},
			},
			{
				Denom: "factory/terp1t7egva48prqmzl59x5ngv4zx0dtrwewc22y7f5/litecoin",
				AuthorityMetadata: types.DenomAuthorityMetadata{
					Admin: "terp1t7egva48prqmzl59x5ngv4zx0dtrwewc22y7f5",
				},
			},
		},
	}

	suite.SetupTestForInitGenesis()
	app := suite.App

	// Test both with bank denom metadata set, and not set.
	for i, denom := range genesisState.FactoryDenoms {
		// hacky, sets bank metadata to exist if i != 0, to cover both cases.
		if i != 0 {
			app.AppKeepers.BankKeeper.SetDenomMetaData(suite.Ctx, banktypes.Metadata{Base: denom.GetDenom()})
		}
	}

	if err := app.AppKeepers.TokenFactoryKeeper.SetParams(suite.Ctx, types.Params{DenomCreationFee: sdk.Coins{sdk.NewInt64Coin("stake", 100)}}); err != nil {
		panic(err)
	}
	app.AppKeepers.TokenFactoryKeeper.InitGenesis(suite.Ctx, genesisState)

	// check that the module account is now initialized
	tokenfactoryModuleAccount := appAppKeepers.AppKeepers.AccountKeeper.GetAccount(suite.Ctx, app.AppKeepers.AccountKeeper.GetModuleAddress(types.ModuleName))
	suite.Require().NotNil(tokenfactoryModuleAccount)

	exportedGenesis := app.AppKeepers.TokenFactoryKeeper.ExportGenesis(suite.Ctx)
	suite.Require().NotNil(exportedGenesis)
	suite.Require().Equal(genesisState, *exportedGenesis)
}
