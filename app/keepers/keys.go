package keepers

import (
	storetypes "github.com/cosmos/cosmos-sdk/store/v2/types"
	upgradetypes "github.com/cosmos/cosmos-sdk/x/upgrade/types"
	ibchookstypes "github.com/cosmos/ibc-apps/modules/ibc-hooks/v11/types"
	ibcwasmtypes "github.com/cosmos/ibc-go/modules/light-clients/08-wasm/v11/types"
	icacontrollertypes "github.com/cosmos/ibc-go/v11/modules/apps/27-interchain-accounts/controller/types"
	icahosttypes "github.com/cosmos/ibc-go/v11/modules/apps/27-interchain-accounts/host/types"
	packetforwardtypes "github.com/cosmos/ibc-go/v11/modules/apps/packet-forward-middleware/types"
	ibctransfertypes "github.com/cosmos/ibc-go/v11/modules/apps/transfer/types"
	ibcexported "github.com/cosmos/ibc-go/v11/modules/core/exported"
	"github.com/terpnetwork/terp-core/v6/app/iavlhash"
)

// LegacyParamsStoreKey is the historical x/params KV name. SDK 0.55 removed
// the module; v6.1 still mounts this store so remaining subspace values can
// be copied into module stores, then the keys are wiped.
const LegacyParamsStoreKey = "params"

func alwaysStoreNames() []string {
	return []string{
		upgradetypes.StoreKey,
		ibcexported.StoreKey,
		ibctransfertypes.StoreKey,
		ibcwasmtypes.StoreKey,
		icahosttypes.StoreKey,
		icacontrollertypes.StoreKey,
		packetforwardtypes.StoreKey,
		ibchookstypes.StoreKey,
		LegacyParamsStoreKey,
	}
}

func (appKeepers *AppKeepers) GenerateKeys() {
	names := alwaysStoreNames()
	if !KeepersOnDest {
		names = append(names, iavlhash.MigratableStores()...)
	}
	if MountDestStores {
		names = append(names, iavlhash.DestStores()...)
	}
	appKeepers.keys = storetypes.NewKVStoreKeys(names...)
	appKeepers.tkeys = storetypes.NewTransientStoreKeys()
}

func (appKeepers *AppKeepers) GetKVStoreKey() map[string]*storetypes.KVStoreKey {
	return appKeepers.keys
}

func (appKeepers *AppKeepers) GetTransientStoreKey() map[string]*storetypes.TransientStoreKey {
	return appKeepers.tkeys
}

// GetKey returns the KVStoreKey mounted under storeKey, or nil.
func (appKeepers *AppKeepers) GetKey(storeKey string) *storetypes.KVStoreKey {
	return appKeepers.keys[storeKey]
}

// KeeperKey is the store key keepers should use for a module StoreKey constant.
// On the v6.4.0 ELF, migratable modules are wired to dest `b3-*` keys.
func (appKeepers *AppKeepers) KeeperKey(storeKey string) *storetypes.KVStoreKey {
	if KeepersOnDest {
		if dst := appKeepers.keys[iavlhash.DestName(storeKey)]; dst != nil {
			return dst
		}
	}
	return appKeepers.keys[storeKey]
}

func (appKeepers *AppKeepers) GetTKey(storeKey string) *storetypes.TransientStoreKey {
	return appKeepers.tkeys[storeKey]
}

func (appKeepers *AppKeepers) GetMemKey(storeKey string) *storetypes.MemoryStoreKey {
	return appKeepers.memKeys[storeKey]
}
