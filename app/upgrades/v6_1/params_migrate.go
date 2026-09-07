package v6_1

import (
	"cosmossdk.io/math"
	"github.com/cosmos/cosmos-sdk/codec"
	"github.com/cosmos/cosmos-sdk/std"
	storetypes "github.com/cosmos/cosmos-sdk/store/v2/types"
	sdk "github.com/cosmos/cosmos-sdk/types"

	wasmkeeper "github.com/CosmWasm/wasmd/x/wasm/keeper"
	wasmtypes "github.com/CosmWasm/wasmd/x/wasm/types"

	"github.com/terpnetwork/terp-core/v6/app/keepers"
	appparams "github.com/terpnetwork/terp-core/v6/app/params"
	"github.com/terpnetwork/terp-core/v6/app/upgrades"
	feesharetypes "github.com/terpnetwork/terp-core/v6/x/feeshare/types"
	globalfeetypes "github.com/terpnetwork/terp-core/v6/x/globalfee/types"
	smartaccounttypes "github.com/terpnetwork/terp-core/v6/x/smart-account/types"
	tokenfactorytypes "github.com/terpnetwork/terp-core/v6/x/tokenfactory/types"
)

// migrateLegacyParams copies leftover x/params subspace values (amino JSON)
// into module KV stores. SDK 0.55 deleted x/params, so this is the last chance
// to read those keys. If a module store already has params, it is left alone.
// If the subspace is empty, known Terp defaults are written so queries work.
func migrateLegacyParams(ctx sdk.Context, k *keepers.AppKeepers) error {
	if k == nil {
		return nil
	}
	logger := ctx.Logger().With("upgrade", UpgradeName)
	amino := codec.NewLegacyAmino()
	std.RegisterLegacyAminoCodec(amino)

	var pstore storetypes.KVStore
	if pk := k.GetKey(keepers.LegacyParamsStoreKey); pk != nil {
		pstore = ctx.KVStore(pk)
	}

	bond := upgrades.GetChainsDenomToken(ctx.ChainID())
	if bond == "" {
		bond = appparams.DefaultBondDenom
	}

	if err := migrateTokenfactory(ctx, k, pstore, amino, bond); err != nil {
		return err
	}
	if err := migrateSmartAccount(ctx, k, pstore, amino); err != nil {
		return err
	}
	if err := migrateFeeshare(ctx, k, pstore, amino); err != nil {
		return err
	}
	if err := migrateGlobalfee(ctx, k, pstore, amino, bond); err != nil {
		return err
	}
	if err := migrateWasm(ctx, k, pstore, amino); err != nil {
		return err
	}
	if err := migrateHashMerchant(ctx, k); err != nil {
		return err
	}

	n := wipeStore(pstore)
	logger.Info("v6.1: legacy params subspace copied and wiped", "keys_removed", n)
	return nil
}

func migrateTokenfactory(ctx sdk.Context, k *keepers.AppKeepers, pstore storetypes.KVStore, amino *codec.LegacyAmino, bond string) error {
	if k.TokenFactoryKeeper == nil || k.GetKey(tokenfactorytypes.StoreKey) == nil {
		return nil
	}
	if ctx.KVStore(k.GetKey(tokenfactorytypes.StoreKey)).Get(tokenfactorytypes.ParamsKey) != nil {
		return nil
	}
	p := tokenfactorytypes.DefaultParams()
	p.DenomCreationFee = sdk.NewCoins(sdk.NewInt64Coin(bond, 10_000_000))
	var fee sdk.Coins
	if aminoGet(pstore, tokenfactorytypes.ModuleName, tokenfactorytypes.KeyDenomCreationFee, amino, &fee) && fee != nil {
		p.DenomCreationFee = fee
	}
	var gas uint64
	if aminoGet(pstore, tokenfactorytypes.ModuleName, tokenfactorytypes.KeyDenomCreationGasConsume, amino, &gas) {
		p.DenomCreationGasConsume = gas
	}
	k.TokenFactoryKeeper.SetParams(ctx, p)
	ctx.Logger().Info("v6.1: tokenfactory params in module store")
	return nil
}

func migrateSmartAccount(ctx sdk.Context, k *keepers.AppKeepers, pstore storetypes.KVStore, amino *codec.LegacyAmino) error {
	if k.SmartAccountKeeper == nil {
		return nil
	}
	if k.SmartAccountKeeper.HasModuleParams(ctx) {
		return nil
	}
	p := smartaccounttypes.DefaultParams()
	var gas uint64
	if aminoGet(pstore, smartaccounttypes.ModuleName, smartaccounttypes.KeyMaximumUnauthenticatedGas, amino, &gas) {
		p.MaximumUnauthenticatedGas = gas
	}
	var active bool
	if aminoGet(pstore, smartaccounttypes.ModuleName, smartaccounttypes.KeyIsSmartAccountActive, amino, &active) {
		p.IsSmartAccountActive = active
	}
	var ctrls []string
	if aminoGet(pstore, smartaccounttypes.ModuleName, smartaccounttypes.KeyCircuitBreakerControllers, amino, &ctrls) {
		p.CircuitBreakerControllers = ctrls
	}
	k.SmartAccountKeeper.SetParams(ctx, p)
	ctx.Logger().Info("v6.1: smartaccount params in module store")
	return nil
}

func migrateFeeshare(ctx sdk.Context, k *keepers.AppKeepers, pstore storetypes.KVStore, amino *codec.LegacyAmino) error {
	if k.FeeShareKeeper == nil || k.GetKey(feesharetypes.StoreKey) == nil {
		return nil
	}
	if ctx.KVStore(k.GetKey(feesharetypes.StoreKey)).Get(feesharetypes.ParamsKey) != nil {
		return nil
	}
	p := feesharetypes.DefaultParams()
	var en bool
	if aminoGet(pstore, feesharetypes.ModuleName, feesharetypes.ParamStoreKeyEnableFeeShare, amino, &en) {
		p.EnableFeeShare = en
	}
	var shares math.LegacyDec
	if aminoGet(pstore, feesharetypes.ModuleName, feesharetypes.ParamStoreKeyDeveloperShares, amino, &shares) && !shares.IsNil() {
		p.DeveloperShares = shares
	}
	var denoms []string
	if aminoGet(pstore, feesharetypes.ModuleName, feesharetypes.ParamStoreKeyAllowedDenoms, amino, &denoms) {
		p.AllowedDenoms = denoms
	}
	return k.FeeShareKeeper.SetParams(ctx, p)
}

func migrateGlobalfee(ctx sdk.Context, k *keepers.AppKeepers, pstore storetypes.KVStore, amino *codec.LegacyAmino, bond string) error {
	if k.GlobalFeeKeeper == nil || k.GetKey(globalfeetypes.StoreKey) == nil {
		return nil
	}
	if ctx.KVStore(k.GetKey(globalfeetypes.StoreKey)).Get(globalfeetypes.ParamsKey) != nil {
		return nil
	}
	p := globalfeetypes.Params{
		MinimumGasPrices: sdk.NewDecCoins(sdk.NewDecCoinFromDec(bond, math.LegacyNewDecWithPrec(75, 3))),
	}
	var prices sdk.DecCoins
	if aminoGet(pstore, globalfeetypes.ModuleName, globalfeetypes.ParamStoreKeyMinGasPrices, amino, &prices) && prices != nil {
		p.MinimumGasPrices = prices
	}
	return k.GlobalFeeKeeper.SetParams(ctx, p)
}

// wasm params moved into the module store at consensus 2→3. morocco-1 should
// already have them. GetParams panics if the collections item is missing, so
// we copy from the leftover wasm subspace (or DefaultParams) when absent.
func migrateWasm(ctx sdk.Context, k *keepers.AppKeepers, pstore storetypes.KVStore, amino *codec.LegacyAmino) error {
	if k.WasmKeeper == nil {
		return nil
	}
	if wasmHasParams(ctx, k.WasmKeeper) {
		return nil
	}
	p := wasmtypes.DefaultParams()
	var access wasmtypes.AccessConfig
	if aminoGet(pstore, wasmtypes.ModuleName, []byte("uploadAccess"), amino, &access) {
		p.CodeUploadAccess = access
	}
	var inst wasmtypes.AccessType
	if aminoGet(pstore, wasmtypes.ModuleName, []byte("instantiateAccess"), amino, &inst) {
		p.InstantiateDefaultPermission = inst
	}
	ctx.Logger().Info("v6.1: wasm params written to module store")
	return k.WasmKeeper.SetParams(ctx, p)
}

func migrateHashMerchant(ctx sdk.Context, k *keepers.AppKeepers) error {
	if k == nil || k.HashMerchantKeeper == nil {
		return nil
	}
	if err := k.HashMerchantKeeper.EnsureSudoGasLimit(ctx); err != nil {
		return err
	}
	p, err := k.HashMerchantKeeper.GetParams(ctx)
	if err != nil {
		return err
	}
	ctx.Logger().Info("v6.1: hashmerchant sudo gas limit", "contract_gas_limit", p.SudoGasLimit())
	return nil
}

func wasmHasParams(ctx sdk.Context, wk *wasmkeeper.Keeper) (ok bool) {
	defer func() {
		if recover() != nil {
			ok = false
		}
	}()
	_ = wk.GetParams(ctx)
	return true
}

func aminoGet(store storetypes.KVStore, subspace string, key []byte, amino *codec.LegacyAmino, ptr any) bool {
	if store == nil || amino == nil {
		return false
	}
	bz := store.Get(subspacePrefixedKey(subspace, key))
	if len(bz) == 0 {
		return false
	}
	return amino.UnmarshalJSON(bz, ptr) == nil
}

func subspacePrefixedKey(name string, key []byte) []byte {
	out := make([]byte, 0, len(name)+1+len(key))
	out = append(out, name...)
	out = append(out, '/')
	return append(out, key...)
}

func wipeStore(store storetypes.KVStore) int {
	if store == nil {
		return 0
	}
	var keys [][]byte
	it := store.Iterator(nil, nil)
	for ; it.Valid(); it.Next() {
		keys = append(keys, append([]byte(nil), it.Key()...))
	}
	it.Close()
	for _, k := range keys {
		store.Delete(k)
	}
	return len(keys)
}
