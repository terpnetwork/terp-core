package types

import (
	"testing"

	"github.com/stretchr/testify/require"

	sdk "github.com/cosmos/cosmos-sdk/types"
)

func TestSplitCircuitRunway(t *testing.T) {
	val, dev := SplitCircuitRunway(sdk.NewCoins(sdk.NewInt64Coin("stake", 1_000_000)))
	require.Equal(t, "500000stake", val.String())
	require.Equal(t, "500000stake", dev.String())

	val, dev = SplitCircuitRunway(sdk.NewCoins(sdk.NewInt64Coin("stake", 1)))
	require.True(t, val.Empty())
	require.Equal(t, "1stake", dev.String())
}
