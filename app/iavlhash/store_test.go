package iavlhash

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestDualStorePairsCoverMigratableNotIBC(t *testing.T) {
	pairs := DualStorePairs()
	require.Equal(t, len(MigratableStores()), len(pairs))
	require.Equal(t, "bank", pairs[0][0], "bank first (upgrade tests snap[0])")

	seen := map[string]struct{}{}
	for _, p := range pairs {
		src, dst := p[0], p[1]
		require.Equal(t, DestName(src), dst)
		require.Equal(t, "blake3", AlgorithmName(src), src)
		require.Equal(t, "blake3", AlgorithmName(dst), dst)
		require.True(t, strings.HasPrefix(dst, "b3-"))
		require.False(t, strings.HasPrefix(src, dst))
		require.False(t, strings.HasPrefix(dst, src), "dest %s shares prefix with live %s", dst, src)
		_, dup := seen[src]
		require.False(t, dup, src)
		seen[src] = struct{}{}
		_, ibc := SHA256Stores[src]
		require.False(t, ibc, "IBC store %s must not be dual-copied", src)
	}

	for name := range SHA256Stores {
		require.NotContains(t, seen, name)
	}
	require.NotContains(t, seen, "08-wasm")
	require.NotContains(t, seen, "params")
	require.Equal(t, DestStores(), destFromPairs(pairs))
}

func destFromPairs(pairs [][2]string) []string {
	out := make([]string, len(pairs))
	for i, p := range pairs {
		out[i] = p[1]
	}
	return out
}
