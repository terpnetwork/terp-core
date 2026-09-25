package v6_4_test

import (
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/terpnetwork/terp-core/v6/app/iavl"
	v64 "github.com/terpnetwork/terp-core/v6/app/upgrades/v6_4"
)

func TestNoRenameOntoExistingKeeperNames(t *testing.T) {
	require.Empty(t, v64.Upgrade.StoreUpgrades.Renamed)
	require.Empty(t, v64.Upgrade.StoreUpgrades.Added)
	require.Equal(t, iavl.MigratableStores(), v64.Upgrade.StoreUpgrades.Deleted)
	require.Equal(t, "v6.4", v64.UpgradeName)
	require.NotContains(t, v64.Upgrade.StoreUpgrades.Deleted, "ibc")
	require.NotContains(t, v64.Upgrade.StoreUpgrades.Deleted, "08-wasm")
	require.Contains(t, v64.Upgrade.StoreUpgrades.Deleted, "bank")
}
