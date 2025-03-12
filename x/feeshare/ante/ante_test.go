package ante_test

import (
	"testing"

	"cosmossdk.io/math"

	"github.com/stretchr/testify/suite"

	sdk "github.com/cosmos/cosmos-sdk/types"

	ante "github.com/terpnetwork/terp-core/v4/x/feeshare/ante"
)

type AnteTestSuite struct {
	suite.Suite
}

func TestAnteSuite(t *testing.T) {
	suite.Run(t, new(AnteTestSuite))
}

func (suite *AnteTestSuite) TestFeeLogic() {
	// We expect all to pass
	feeCoins := sdk.NewCoins(sdk.NewCoin("uthiol", math.NewInt(500)), sdk.NewCoin("utoken", math.NewInt(250)))

	testCases := []struct {
		name               string
		incomingFee        sdk.Coins
		govPercent         math.LegacyDec
		numContracts       int
		expectedFeePayment sdk.Coins
	}{
		{
			"100% fee / 1 contract",
			feeCoins,
			math.LegacyNewDecWithPrec(100, 2),
			1,
			sdk.NewCoins(sdk.NewCoin("uthiol", math.NewInt(500)), sdk.NewCoin("utoken", math.NewInt(250))),
		},
		{
			"100% fee / 2 contracts",
			feeCoins,
			math.LegacyNewDecWithPrec(100, 2),
			2,
			sdk.NewCoins(sdk.NewCoin("uthiol", math.NewInt(250)), sdk.NewCoin("utoken", math.NewInt(125))),
		},
		{
			"100% fee / 10 contracts",
			feeCoins,
			math.LegacyNewDecWithPrec(100, 2),
			10,
			sdk.NewCoins(sdk.NewCoin("uthiol", math.NewInt(50)), sdk.NewCoin("utoken", math.NewInt(25))),
		},
		{
			"67% fee / 7 contracts",
			feeCoins,
			math.LegacyNewDecWithPrec(67, 2),
			7,
			sdk.NewCoins(sdk.NewCoin("uthiol", math.NewInt(48)), sdk.NewCoin("utoken", math.NewInt(24))),
		},
		{
			"50% fee / 1 contracts",
			feeCoins,
			math.LegacyNewDecWithPrec(50, 2),
			1,
			sdk.NewCoins(sdk.NewCoin("uthiol", math.NewInt(250)), sdk.NewCoin("utoken", math.NewInt(125))),
		},
		{
			"50% fee / 2 contracts",
			feeCoins,
			math.LegacyNewDecWithPrec(50, 2),
			2,
			sdk.NewCoins(sdk.NewCoin("uthiol", math.NewInt(125)), sdk.NewCoin("utoken", math.NewInt(62))),
		},
		{
			"50% fee / 3 contracts",
			feeCoins,
			math.LegacyNewDecWithPrec(50, 2),
			3,
			sdk.NewCoins(sdk.NewCoin("uthiol", math.NewInt(83)), sdk.NewCoin("utoken", math.NewInt(42))),
		},
		{
			"25% fee / 2 contracts",
			feeCoins,
			math.LegacyNewDecWithPrec(25, 2),
			2,
			sdk.NewCoins(sdk.NewCoin("uthiol", math.NewInt(62)), sdk.NewCoin("utoken", math.NewInt(31))),
		},
		{
			"15% fee / 3 contracts",
			feeCoins,
			math.LegacyNewDecWithPrec(15, 2),
			3,
			sdk.NewCoins(sdk.NewCoin("uthiol", math.NewInt(25)), sdk.NewCoin("utoken", math.NewInt(12))),
		},
		{
			"1% fee / 2 contracts",
			feeCoins,
			math.LegacyNewDecWithPrec(1, 2),
			2,
			sdk.NewCoins(sdk.NewCoin("uthiol", math.NewInt(2)), sdk.NewCoin("utoken", math.NewInt(1))),
		},
	}

	for _, tc := range testCases {
		coins := ante.FeePayLogic(tc.incomingFee, tc.govPercent, tc.numContracts)

		for _, coin := range coins {
			for _, expectedCoin := range tc.expectedFeePayment {
				if coin.Denom == expectedCoin.Denom {
					suite.Require().Equal(expectedCoin.Amount.Int64(), coin.Amount.Int64(), tc.name)
				}
			}
		}
	}
}
