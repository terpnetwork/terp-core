package keepers

import (
	wasmtypes "github.com/CosmWasm/wasmd/x/wasm/types"
	crisistypes "github.com/cosmos/cosmos-sdk/contrib/x/crisis/types"
	storetypes "github.com/cosmos/cosmos-sdk/store/v2/types"
	authtypes "github.com/cosmos/cosmos-sdk/x/auth/types"
	authzkeeper "github.com/cosmos/cosmos-sdk/x/authz/keeper"
	banktypes "github.com/cosmos/cosmos-sdk/x/bank/types"
	consensusparamtypes "github.com/cosmos/cosmos-sdk/x/consensus/types"
	distrtypes "github.com/cosmos/cosmos-sdk/x/distribution/types"
	evidencetypes "github.com/cosmos/cosmos-sdk/x/evidence/types"
	"github.com/cosmos/cosmos-sdk/x/feegrant"
	govtypes "github.com/cosmos/cosmos-sdk/x/gov/types"
	minttypes "github.com/cosmos/cosmos-sdk/x/mint/types"
	paramstypes "github.com/cosmos/cosmos-sdk/x/params/types"
	slashingtypes "github.com/cosmos/cosmos-sdk/x/slashing/types"
	stakingtypes "github.com/cosmos/cosmos-sdk/x/staking/types"
	upgradetypes "github.com/cosmos/cosmos-sdk/x/upgrade/types"
	ibchookstypes "github.com/cosmos/ibc-apps/modules/ibc-hooks/v11/types"
	ibcwasmtypes "github.com/cosmos/ibc-go/modules/light-clients/08-wasm/v11/types"
	icacontrollertypes "github.com/cosmos/ibc-go/v11/modules/apps/27-interchain-accounts/controller/types"
	icahosttypes "github.com/cosmos/ibc-go/v11/modules/apps/27-interchain-accounts/host/types"
	packetforwardtypes "github.com/cosmos/ibc-go/v11/modules/apps/packet-forward-middleware/types"
	ibctransfertypes "github.com/cosmos/ibc-go/v11/modules/apps/transfer/types"
	ibcexported "github.com/cosmos/ibc-go/v11/modules/core/exported"
	cwhookstypes "github.com/terpnetwork/terp-core/v6/x/cw-hooks/types"
	driptypes "github.com/terpnetwork/terp-core/v6/x/drip/types"
	feesharetypes "github.com/terpnetwork/terp-core/v6/x/feeshare/types"
	globalfeetypes "github.com/terpnetwork/terp-core/v6/x/globalfee/types"
	hashmerchanttypes "github.com/terpnetwork/terp-core/v6/x/hashmerchant/types"
	smartaccounttypes "github.com/terpnetwork/terp-core/v6/x/smart-account/types"
	tokenfactorytypes "github.com/terpnetwork/terp-core/v6/x/tokenfactory/types"
)

func (appKeepers *AppKeepers) GenerateKeys() {
	appKeepers.keys = storetypes.NewKVStoreKeys(
		authtypes.StoreKey,
		banktypes.StoreKey,
		stakingtypes.StoreKey,
		crisistypes.StoreKey,
		minttypes.StoreKey,
		distrtypes.StoreKey,
		slashingtypes.StoreKey,
		govtypes.StoreKey,
		paramstypes.StoreKey,
		consensusparamtypes.StoreKey,
		upgradetypes.StoreKey,
		feegrant.StoreKey,
		evidencetypes.StoreKey,
		authzkeeper.StoreKey,
		// non sdk store keys
		ibcexported.StoreKey,
		ibctransfertypes.StoreKey,
		wasmtypes.StoreKey,
		ibcwasmtypes.StoreKey,
		icahosttypes.StoreKey,
		icacontrollertypes.StoreKey,
		packetforwardtypes.StoreKey,
		ibchookstypes.StoreKey,
		feesharetypes.StoreKey,
		globalfeetypes.StoreKey,
		driptypes.StoreKey,
		smartaccounttypes.StoreKey,
		tokenfactorytypes.StoreKey,
		hashmerchanttypes.StoreKey,
		cwhookstypes.StoreKey,
	)

	appKeepers.tkeys = storetypes.NewTransientStoreKeys(paramstypes.TStoreKey)
}

func (appKeepers *AppKeepers) GetKVStoreKey() map[string]*storetypes.KVStoreKey {
	return appKeepers.keys
}

func (appKeepers *AppKeepers) GetTransientStoreKey() map[string]*storetypes.TransientStoreKey {
	return appKeepers.tkeys
}

// GetKey returns the KVStoreKey for the provided store key.
//
// NOTE: This is solely to be used for testing purposes.
func (appKeepers *AppKeepers) GetKey(storeKey string) *storetypes.KVStoreKey {
	return appKeepers.keys[storeKey]
}

// GetTKey returns the TransientStoreKey for the provided store key.
//
// NOTE: This is solely to be used for testing purposes.
func (appKeepers *AppKeepers) GetTKey(storeKey string) *storetypes.TransientStoreKey {
	return appKeepers.tkeys[storeKey]
}

// GetMemKey returns the MemStoreKey for the provided mem key.
//
// NOTE: This is solely used for testing purposes.
func (appKeepers *AppKeepers) GetMemKey(storeKey string) *storetypes.MemoryStoreKey {
	return appKeepers.memKeys[storeKey]
}
