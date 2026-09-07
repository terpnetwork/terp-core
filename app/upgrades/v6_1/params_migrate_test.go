package v6_1

import (
	"testing"

	"github.com/stretchr/testify/require"

	tokenfactorytypes "github.com/terpnetwork/terp-core/v6/x/tokenfactory/types"
)

func TestSubspacePrefixedKey(t *testing.T) {
	got := subspacePrefixedKey("tokenfactory", tokenfactorytypes.KeyDenomCreationFee)
	require.Equal(t, []byte("tokenfactory/DenomCreationFee"), got)
}
