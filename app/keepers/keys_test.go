package keepers

import (
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/terpnetwork/terp-core/v6/app/iavl"
)

func TestGenerateKeysLayout(t *testing.T) {
	var k AppKeepers
	k.GenerateKeys()
	require.NotNil(t, k.GetKey("ibc"))
	require.Nil(t, k.GetKey("b3-ibc"))
	if KeepersOnDest {
		require.Nil(t, k.GetKey("bank"))
		require.NotNil(t, k.GetKey(iavl.BankB3))
		require.Equal(t, iavl.BankB3, k.KeeperKey("bank").Name())
		require.Nil(t, k.GetKey("wasm"))
		require.NotNil(t, k.KeeperKey("wasm"))
		require.Equal(t, iavl.DestName("wasm"), k.KeeperKey("wasm").Name())
		return
	}
	require.NotNil(t, k.GetKey("bank"))
	if MountDestStores {
		require.NotNil(t, k.GetKey(iavl.BankB3))
		require.Equal(t, "bank", k.KeeperKey("bank").Name())
	} else {
		require.Nil(t, k.GetKey(iavl.BankB3))
	}
}
