package keeper

import (
	"context"
	"encoding/binary"
	"fmt"

	"cosmossdk.io/log"
	"cosmossdk.io/store/prefix"
	storetypes "cosmossdk.io/store/types"
	"github.com/cosmos/cosmos-sdk/codec"
	sdk "github.com/cosmos/cosmos-sdk/types"

	"github.com/terpnetwork/terp-core/v5/x/hashmerchant/types"
)

// Keeper manages the x/hashmerchant module state.
type Keeper struct {
	cdc      codec.BinaryCodec
	storeKey storetypes.StoreKey

	authority string // gov module address

	accountKeeper types.AccountKeeper
	bankKeeper    types.BankKeeper
	stakingKeeper types.StakingKeeper
	wasmKeeper    types.WasmKeeper

	config HashMerchantConfig
}

// NewKeeper creates a new hashmerchant keeper.
func NewKeeper(
	cdc codec.BinaryCodec,
	storeKey storetypes.StoreKey,
	authority string,
	accountKeeper types.AccountKeeper,
	bankKeeper types.BankKeeper,
	stakingKeeper types.StakingKeeper,
	wasmKeeper types.WasmKeeper,
	config HashMerchantConfig,
) Keeper {
	return Keeper{
		cdc:           cdc,
		storeKey:      storeKey,
		authority:     authority,
		accountKeeper: accountKeeper,
		bankKeeper:    bankKeeper,
		stakingKeeper: stakingKeeper,
		wasmKeeper:    wasmKeeper,
		config:        config,
	}
}

func (k Keeper) GetAuthority() string { return k.authority }

func (k Keeper) Logger(ctx sdk.Context) log.Logger {
	return ctx.Logger().With("module", fmt.Sprintf("x/%s", types.ModuleName))
}

// ---------------------------------------------------------------------------
// Params
// ---------------------------------------------------------------------------

func (k Keeper) GetParams(ctx context.Context) (types.Params, error) {
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	store := sdkCtx.KVStore(k.storeKey)
	bz := store.Get(types.KeyPrefixParams)
	if bz == nil {
		return types.DefaultParams(), nil
	}
	var p types.Params
	if err := k.cdc.Unmarshal(bz, &p); err != nil {
		return types.Params{}, err
	}
	return p, nil
}

func (k Keeper) SetParams(ctx context.Context, p types.Params) error {
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	bz, err := k.cdc.Marshal(&p)
	if err != nil {
		return err
	}
	sdkCtx.KVStore(k.storeKey).Set(types.KeyPrefixParams, bz)
	return nil
}

// ---------------------------------------------------------------------------
// RegisteredChain CRUD
// ---------------------------------------------------------------------------

func (k Keeper) SetRegisteredChain(ctx context.Context, chain types.RegisteredChain) error {
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	bz, err := k.cdc.Marshal(&chain)
	if err != nil {
		return err
	}
	sdkCtx.KVStore(k.storeKey).Set(types.KeyRegisteredChain(chain.ChainUid), bz)
	return nil
}

func (k Keeper) GetRegisteredChain(ctx context.Context, chainUID string) (types.RegisteredChain, error) {
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	bz := sdkCtx.KVStore(k.storeKey).Get(types.KeyRegisteredChain(chainUID))
	if bz == nil {
		return types.RegisteredChain{}, types.ErrChainNotFound.Wrapf("chain_uid: %s", chainUID)
	}
	var c types.RegisteredChain
	if err := k.cdc.Unmarshal(bz, &c); err != nil {
		return types.RegisteredChain{}, err
	}
	return c, nil
}

func (k Keeper) HasRegisteredChain(ctx context.Context, chainUID string) bool {
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	return sdkCtx.KVStore(k.storeKey).Has(types.KeyRegisteredChain(chainUID))
}

func (k Keeper) IterateRegisteredChains(ctx context.Context, cb func(types.RegisteredChain) bool) {
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	store := prefix.NewStore(sdkCtx.KVStore(k.storeKey), types.KeyPrefixRegisteredChains)
	iter := store.Iterator(nil, nil)
	defer iter.Close()
	for ; iter.Valid(); iter.Next() {
		var c types.RegisteredChain
		if err := k.cdc.Unmarshal(iter.Value(), &c); err != nil {
			continue
		}
		if cb(c) {
			break
		}
	}
}

// ---------------------------------------------------------------------------
// RegisteredContract CRUD
// ---------------------------------------------------------------------------

func (k Keeper) SetRegisteredContract(ctx context.Context, contract types.RegisteredContract) error {
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	bz, err := k.cdc.Marshal(&contract)
	if err != nil {
		return err
	}
	sdkCtx.KVStore(k.storeKey).Set(types.KeyRegisteredContract(contract.ContractAddr), bz)
	return nil
}

func (k Keeper) GetRegisteredContract(ctx context.Context, contractAddr string) (types.RegisteredContract, error) {
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	bz := sdkCtx.KVStore(k.storeKey).Get(types.KeyRegisteredContract(contractAddr))
	if bz == nil {
		return types.RegisteredContract{}, types.ErrContractNotFound.Wrapf("contract: %s", contractAddr)
	}
	var c types.RegisteredContract
	if err := k.cdc.Unmarshal(bz, &c); err != nil {
		return types.RegisteredContract{}, err
	}
	return c, nil
}

func (k Keeper) IterateRegisteredContracts(ctx context.Context, cb func(types.RegisteredContract) bool) {
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	store := prefix.NewStore(sdkCtx.KVStore(k.storeKey), types.KeyPrefixRegisteredContracts)
	iter := store.Iterator(nil, nil)
	defer iter.Close()
	for ; iter.Valid(); iter.Next() {
		var c types.RegisteredContract
		if err := k.cdc.Unmarshal(iter.Value(), &c); err != nil {
			continue
		}
		if cb(c) {
			break
		}
	}
}

// ---------------------------------------------------------------------------
// EscrowRecord CRUD
// ---------------------------------------------------------------------------

func (k Keeper) SetEscrowRecord(ctx context.Context, record types.EscrowRecord) error {
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	bz, err := k.cdc.Marshal(&record)
	if err != nil {
		return err
	}
	sdkCtx.KVStore(k.storeKey).Set(types.KeyEscrow(record.ContractAddr), bz)
	return nil
}

func (k Keeper) GetEscrowRecord(ctx context.Context, contractAddr string) (types.EscrowRecord, error) {
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	bz := sdkCtx.KVStore(k.storeKey).Get(types.KeyEscrow(contractAddr))
	if bz == nil {
		return types.EscrowRecord{}, types.ErrEscrowNotFound.Wrapf("contract: %s", contractAddr)
	}
	var r types.EscrowRecord
	if err := k.cdc.Unmarshal(bz, &r); err != nil {
		return types.EscrowRecord{}, err
	}
	return r, nil
}

func (k Keeper) IterateEscrowRecords(ctx context.Context, cb func(types.EscrowRecord) bool) {
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	store := prefix.NewStore(sdkCtx.KVStore(k.storeKey), types.KeyPrefixEscrow)
	iter := store.Iterator(nil, nil)
	defer iter.Close()
	for ; iter.Valid(); iter.Next() {
		var r types.EscrowRecord
		if err := k.cdc.Unmarshal(iter.Value(), &r); err != nil {
			continue
		}
		if cb(r) {
			break
		}
	}
}

// ---------------------------------------------------------------------------
// HashRoot CRUD
// ---------------------------------------------------------------------------

func (k Keeper) SetHashRoot(ctx context.Context, root types.HashRoot) error {
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	bz, err := k.cdc.Marshal(&root)
	if err != nil {
		return err
	}
	sdkCtx.KVStore(k.storeKey).Set(types.KeyHashRoot(root.ChainUid, root.Algo), bz)
	return nil
}

func (k Keeper) GetHashRoot(ctx context.Context, chainUID, algo string) (types.HashRoot, error) {
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	bz := sdkCtx.KVStore(k.storeKey).Get(types.KeyHashRoot(chainUID, algo))
	if bz == nil {
		return types.HashRoot{}, types.ErrHashRootNotFound.Wrapf("chain=%s algo=%s", chainUID, algo)
	}
	var r types.HashRoot
	if err := k.cdc.Unmarshal(bz, &r); err != nil {
		return types.HashRoot{}, err
	}
	return r, nil
}

func (k Keeper) IterateHashRoots(ctx context.Context, chainUID string, cb func(types.HashRoot) bool) {
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	// iterate all roots under 0x04 | chainUID |
	pfx := append(types.KeyPrefixHashRoots, []byte(chainUID+"|")...)
	store := prefix.NewStore(sdkCtx.KVStore(k.storeKey), pfx)
	iter := store.Iterator(nil, nil)
	defer iter.Close()
	for ; iter.Valid(); iter.Next() {
		var r types.HashRoot
		if err := k.cdc.Unmarshal(iter.Value(), &r); err != nil {
			continue
		}
		if cb(r) {
			break
		}
	}
}

// ---------------------------------------------------------------------------
// PruneEpoch (last height at which pruning ran)
// ---------------------------------------------------------------------------

func (k Keeper) GetPruneEpoch(ctx context.Context) uint64 {
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	bz := sdkCtx.KVStore(k.storeKey).Get(types.KeyPrefixPruneEpoch)
	if bz == nil {
		return 0
	}
	return binary.BigEndian.Uint64(bz)
}

func (k Keeper) SetPruneEpoch(ctx context.Context, height uint64) {
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	bz := make([]byte, 8)
	binary.BigEndian.PutUint64(bz, height)
	sdkCtx.KVStore(k.storeKey).Set(types.KeyPrefixPruneEpoch, bz)
}

// ---------------------------------------------------------------------------
// CreateModuleAccount ensures the module account exists (called at init).
// ---------------------------------------------------------------------------

func (k Keeper) CreateModuleAccount(ctx context.Context) {
	k.accountKeeper.GetModuleAccount(ctx, types.ModuleName)
}
