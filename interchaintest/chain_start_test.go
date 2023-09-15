package interchaintest

import (
	"testing"

	"github.com/stretchr/testify/require"
)

// TestBasicTerpStart is a basic test to assert that spinning up a Terp network with one validator works properly.
func TestBasicTerpStart(t *testing.T) {
	if testing.Short() {
		t.Skip()
	}

	t.Parallel()

	// Base setup
	chains := CreateThisBranchChain(t, 1, 0)
	ic, ctx, _, _ := BuildInitialChain(t, chains)

	require.NotNil(t, ic)
	require.NotNil(t, ctx)

	t.Cleanup(func() {
		_ = ic.Close()
	})
}
