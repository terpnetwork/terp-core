package app

import (
	"encoding/json"
	"fmt"
	"log"
	"time"

	"cosmossdk.io/math"
	storetypes "github.com/cosmos/cosmos-sdk/store/v2/types"
	upgradetypes "github.com/cosmos/cosmos-sdk/x/upgrade/types"

	"github.com/cometbft/cometbft/crypto"
	"github.com/cometbft/cometbft/libs/bytes"
	tmos "github.com/cometbft/cometbft/libs/os"
	cmtproto "github.com/cometbft/cometbft/proto/tendermint/types"
	"github.com/cosmos/cosmos-sdk/codec/types"
	"github.com/cosmos/cosmos-sdk/crypto/keys/ed25519"
	servertypes "github.com/cosmos/cosmos-sdk/server/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/bech32"
	distrtypes "github.com/cosmos/cosmos-sdk/x/distribution/types"
	slashingtypes "github.com/cosmos/cosmos-sdk/x/slashing/types"
	"github.com/cosmos/cosmos-sdk/x/staking"
	stakingtypes "github.com/cosmos/cosmos-sdk/x/staking/types"
	v520 "github.com/terpnetwork/terp-core/v6/app/upgrades/v520"
	tokenfactorytypes "github.com/terpnetwork/terp-core/v6/x/tokenfactory/types"
)

// ExportAppStateAndValidators exports the state of the application for a genesis
// file.
func (app *TerpApp) ExportAppStateAndValidators(forZeroHeight bool, jailAllowedAddrs []string, modulesToExport []string) (servertypes.ExportedApp, error) {
	// as if they could withdraw from the start of the next block
	ctx := app.NewContext(true)
	// test soundness of export

	// We export at last height + 1, because that's the height at which
	// Tendermint will start InitChain.
	height := app.LastBlockHeight() + 1
	if forZeroHeight {
		height = 0
		app.prepForZeroHeightGenesis(ctx, jailAllowedAddrs)
	} else {
		v520.CustomV6PatchMethod(ctx, &app.AppKeepers, false)
	}

	app.TokenFactoryKeeper.SetParams(ctx, tokenfactorytypes.DefaultParams())

	genState, _ := app.mm.ExportGenesisForModules(ctx, app.appCodec, modulesToExport)
	appState, err := json.MarshalIndent(genState, "", "  ")
	if err != nil {
		return servertypes.ExportedApp{}, err
	}

	// assert invariants
	app.CrisisKeeper.AssertInvariants(ctx)

	validators, err := staking.WriteValidators(ctx, app.StakingKeeper)
	return servertypes.ExportedApp{
		AppState:        appState,
		Validators:      validators,
		Height:          height,
		ConsensusParams: app.BaseApp.GetConsensusParams(ctx),
	}, err
}

// prepare for fresh start at zero height
// NOTE zero height genesis is a temporary feature which will be deprecated
//
//	in favour of export at a block height
func (app *TerpApp) prepForZeroHeightGenesis(ctx sdk.Context, jailAllowedAddrs []string) {
	applyAllowedAddrs := false

	// check if there is a allowed address list
	if len(jailAllowedAddrs) > 0 {
		applyAllowedAddrs = true
	}

	allowedAddrsMap := make(map[string]bool)

	for _, addr := range jailAllowedAddrs {
		_, err := sdk.ValAddressFromBech32(addr)
		if err != nil {
			log.Fatal(err)
		}
		allowedAddrsMap[addr] = true
	}

	v520.CustomV6PatchMethod(ctx, &app.AppKeepers, false)
	/* Just to be safe, assert the invariants on current state. */
	app.CrisisKeeper.AssertInvariants(ctx)

	/* Handle fee distribution state. */

	// withdraw all validator commission
	// err := app.StakingKeeper.IterateValidators(ctx, func(_ int64, val stakingtypes.ValidatorI) (stop bool) {
	// 	_, _ = app.DistrKeeper.WithdrawValidatorCommission(ctx, sdk.ValAddress(val.GetOperator()))
	// 	return false
	// })
	// if err != nil {
	// 	log.Fatal(err)
	// }

	// withdraw all delegator rewards
	dels, _ := app.StakingKeeper.GetAllDelegations(ctx)
	for _, delegation := range dels {
		valAddr, err := sdk.ValAddressFromBech32(delegation.ValidatorAddress)
		if err != nil {
			panic(err)
		}

		delAddr := sdk.MustAccAddressFromBech32(delegation.DelegatorAddress)

		if _, err = app.DistrKeeper.WithdrawDelegationRewards(ctx, delAddr, valAddr); err != nil {
			panic(err)
		}
	}

	// clear validator slash events
	app.DistrKeeper.DeleteAllValidatorSlashEvents(ctx)

	// clear validator historical rewards
	app.DistrKeeper.DeleteAllValidatorHistoricalRewards(ctx)

	// set context height to zero
	height := ctx.BlockHeight()
	ctx = ctx.WithBlockHeight(0)

	// // reinitialize all validators
	// app.StakingKeeper.IterateValidators(ctx, func(_ int64, val stakingtypes.ValidatorI) (stop bool) {
	// 	// donate any unwithdrawn outstanding reward fraction tokens to the community pool
	// 	scraps, _ := app.DistrKeeper.GetValidatorOutstandingRewardsCoins(ctx, sdk.ValAddress(val.GetOperator()))
	// 	feePool, _ := app.DistrKeeper.FeePool.Get(ctx)
	// 	feePool.CommunityPool = feePool.CommunityPool.Add(scraps...)
	// 	app.DistrKeeper.FeePool.Set(ctx, feePool)

	// 	if err := app.DistrKeeper.Hooks().AfterValidatorCreated(ctx, sdk.ValAddress(val.GetOperator())); err != nil {
	// 		panic(err)
	// 	}
	// 	return false
	// })

	// // reinitialize all delegations
	// for _, del := range dels {
	// 	valAddr, err := sdk.ValAddressFromBech32(del.ValidatorAddress)
	// 	if err != nil {
	// 		panic(err)
	// 	}
	// 	delAddr := sdk.MustAccAddressFromBech32(del.DelegatorAddress)

	// 	if err := app.DistrKeeper.Hooks().BeforeDelegationCreated(ctx, delAddr, valAddr); err != nil {
	// 		// never called as BeforeDelegationCreated always returns nil
	// 		panic(fmt.Errorf("error while incrementing period: %w", err))
	// 	}

	// 	if err := app.DistrKeeper.Hooks().AfterDelegationModified(ctx, delAddr, valAddr); err != nil {
	// 		// never called as AfterDelegationModified always returns nil
	// 		panic(fmt.Errorf("error while creating a new delegation period record: %w", err))
	// 	}
	// }

	// reset context height
	ctx = ctx.WithBlockHeight(height)

	/* Handle staking state. */

	// iterate through redelegations, reset creation height
	app.StakingKeeper.IterateRedelegations(ctx, func(_ int64, red stakingtypes.Redelegation) (stop bool) {
		for i := range red.Entries {
			red.Entries[i].CreationHeight = 0
		}
		app.StakingKeeper.SetRedelegation(ctx, red)
		return false
	})

	// iterate through unbonding delegations, reset creation height
	app.StakingKeeper.IterateUnbondingDelegations(ctx, func(_ int64, ubd stakingtypes.UnbondingDelegation) (stop bool) {
		for i := range ubd.Entries {
			ubd.Entries[i].CreationHeight = 0
		}
		app.StakingKeeper.SetUnbondingDelegation(ctx, ubd)
		return false
	})

	// Iterate through validators by power descending, reset bond heights, and
	// update bond intra-tx counters.
	store := ctx.KVStore(app.GetKey(stakingtypes.StoreKey))
	iter := storetypes.KVStoreReversePrefixIterator(store, stakingtypes.ValidatorsKey)
	counter := int16(0)

	for ; iter.Valid(); iter.Next() {
		addr := sdk.ValAddress(stakingtypes.AddressFromValidatorsKey(iter.Key()))
		validator, err := app.StakingKeeper.GetValidator(ctx, addr)
		if err != nil {
			panic("expected validator, not found")
		}

		validator.UnbondingHeight = 0
		if applyAllowedAddrs && !allowedAddrsMap[addr.String()] {
			validator.Jailed = true
		}

		app.StakingKeeper.SetValidator(ctx, validator)
		counter++
	}

	if err := iter.Close(); err != nil {
		app.Logger().Error("error while closing the key-value store reverse prefix iterator: ", err)
		return
	}

	_, err := app.StakingKeeper.ApplyAndReturnValidatorSetUpdates(ctx)
	if err != nil {
		log.Fatal(err)
	}

	/* Handle slashing state. */

	// reset start height on signing infos
	app.SlashingKeeper.IterateValidatorSigningInfos(
		ctx,
		func(addr sdk.ConsAddress, info slashingtypes.ValidatorSigningInfo) (stop bool) {
			info.StartHeight = 0
			app.SlashingKeeper.SetValidatorSigningInfo(ctx, addr, info)
			return false
		},
	)
}

// source: https://github.com/osmosis-labs/osmosis/blob/7b1a78d397b632247fe83f51867f319adf3a858c/app/app.go#L786
// one-liner: cd ../terp-snapshots && terpd comet unsafe-reset-all && cp ~/.terpd/data/priv_validator_state.json ~/.terpd/priv_validator_state.json && lz4 -c -d <terp-snapshot>.tar.lz4 | tar -x -C $HOME/.terpd && cp ~/.terpd/priv_validator_state.json ~/.terpd/data/priv_validator_state.json && cd ../go-terp && make install && terpd in-place-testnet test1 terp1mt3wj088jvurp3vlh2yfar6vqrqp0llnsj8lar terpvaloper1qxw4fjged2xve8ez7nu779tm8ejw92rv0vcuqr
func InitTerpAppForTestnet(app *TerpApp, newValAddr bytes.HexBytes, newValPubKey crypto.PubKey, newOperatorAddress, upgradeToTrigger string) *TerpApp {
	ctx := app.BaseApp.NewUncachedContext(true, cmtproto.Header{})
	pubkey := &ed25519.PubKey{Key: newValPubKey.Bytes()}
	pubkeyAny, err := types.NewAnyWithValue(pubkey)
	if err != nil {
		tmos.Exit(err.Error())
	}
	// Create Validator struct for our new validator.
	_, bz, err := bech32.DecodeAndConvert(newOperatorAddress)
	if err != nil {
		tmos.Exit(err.Error())
	}
	bech32Addr, err := bech32.ConvertAndEncode("terpvaloper", bz)
	if err != nil {
		tmos.Exit(err.Error())
	}
	fmt.Printf("bech32Addr: %v\n", bech32Addr)
	newVal := stakingtypes.Validator{
		OperatorAddress: bech32Addr,
		ConsensusPubkey: pubkeyAny,
		Jailed:          false,
		Status:          stakingtypes.Bonded,
		Tokens:          math.NewInt(900000000000000),
		DelegatorShares: math.LegacyMustNewDecFromStr("10000000"),
		Description: stakingtypes.Description{
			Moniker: "Testnet Validator",
		},
		Commission: stakingtypes.Commission{
			CommissionRates: stakingtypes.CommissionRates{
				Rate:          math.LegacyMustNewDecFromStr("0.05"),
				MaxRate:       math.LegacyMustNewDecFromStr("0.1"),
				MaxChangeRate: math.LegacyMustNewDecFromStr("0.05"),
			},
		},
		MinSelfDelegation: math.OneInt(),
	}

	// Remove all validators from power store
	stakingKey := app.GetKey(stakingtypes.ModuleName)
	stakingStore := ctx.KVStore(stakingKey)
	iterator, err := app.StakingKeeper.ValidatorsPowerStoreIterator(ctx)
	if err != nil {
		tmos.Exit(err.Error())
	}
	for ; iterator.Valid(); iterator.Next() {
		stakingStore.Delete(iterator.Key())
	}
	iterator.Close()

	// Remove all valdiators from last validators store
	iterator, err = app.StakingKeeper.LastValidatorsIterator(ctx)
	if err != nil {
		tmos.Exit(err.Error())
	}
	for ; iterator.Valid(); iterator.Next() {
		stakingStore.Delete(iterator.Key())
	}
	iterator.Close()

	//  TODO: retain validator from store
	// Remove all validators from validators store
	iterator = storetypes.KVStorePrefixIterator(stakingStore, stakingtypes.ValidatorsKey)
	for ; iterator.Valid(); iterator.Next() {
		stakingStore.Delete(iterator.Key())
	}
	iterator.Close()

	// Remove all validators from unbonding queue
	iterator = storetypes.KVStorePrefixIterator(stakingStore, stakingtypes.ValidatorQueueKey)
	for ; iterator.Valid(); iterator.Next() {
		stakingStore.Delete(iterator.Key())
	}
	iterator.Close()

	// Add our validator to power and last validators store
	err = app.StakingKeeper.SetValidator(ctx, newVal)
	if err != nil {
		tmos.Exit(err.Error())
	}

	err = app.StakingKeeper.SetValidatorByConsAddr(ctx, newVal)
	if err != nil {
		tmos.Exit(err.Error())
	}

	err = app.StakingKeeper.SetValidatorByPowerIndex(ctx, newVal)
	if err != nil {
		tmos.Exit(err.Error())
	}

	valAddr, err := sdk.ValAddressFromBech32(newVal.GetOperator())
	if err != nil {
		tmos.Exit(err.Error())
	}

	err = app.StakingKeeper.SetLastValidatorPower(ctx, valAddr, 1)
	if err != nil {
		tmos.Exit(err.Error())
	}

	if err := app.StakingKeeper.Hooks().AfterValidatorCreated(ctx, valAddr); err != nil {
		panic(err)
	}
	// Initialize records for this validator across all distribution stores
	valAddr, err = sdk.ValAddressFromBech32(newVal.GetOperator())
	if err != nil {
		tmos.Exit(err.Error())
	}
	err = app.DistrKeeper.SetValidatorHistoricalRewards(ctx, valAddr, 0, distrtypes.NewValidatorHistoricalRewards(sdk.DecCoins{}, 1))
	if err != nil {
		tmos.Exit(err.Error())
	}
	err = app.DistrKeeper.SetValidatorCurrentRewards(ctx, valAddr, distrtypes.NewValidatorCurrentRewards(sdk.DecCoins{}, 1))
	if err != nil {
		tmos.Exit(err.Error())
	}
	err = app.DistrKeeper.SetValidatorAccumulatedCommission(ctx, valAddr, distrtypes.InitialValidatorAccumulatedCommission())
	if err != nil {
		tmos.Exit(err.Error())
	}
	err = app.DistrKeeper.SetValidatorOutstandingRewards(ctx, valAddr, distrtypes.ValidatorOutstandingRewards{Rewards: sdk.DecCoins{}})
	if err != nil {
		tmos.Exit(err.Error())
	}

	// SLASHING
	// Set validator signing info for our new validator.
	newConsAddr := sdk.ConsAddress(newValAddr.Bytes())
	newValidatorSigningInfo := slashingtypes.ValidatorSigningInfo{
		Address:     newConsAddr.String(),
		StartHeight: app.LastBlockHeight() - 1,
		Tombstoned:  false,
	}
	err = app.SlashingKeeper.SetValidatorSigningInfo(ctx, newConsAddr, newValidatorSigningInfo)
	if err != nil {
		tmos.Exit(err.Error())
	}

	newExpeditedVotingPeriod := time.Minute
	newVotingPeriod := time.Minute * 2

	govParams, err := app.GovKeeper.Params.Get(ctx)
	if err != nil {
		tmos.Exit(err.Error())
	}

	govParams.ExpeditedVotingPeriod = &newExpeditedVotingPeriod
	govParams.VotingPeriod = &newVotingPeriod
	govParams.MinDeposit = sdk.NewCoins(sdk.NewInt64Coin("uterp", 100000000))
	govParams.ExpeditedMinDeposit = sdk.NewCoins(sdk.NewInt64Coin("uterp", 150000000))
	err = app.GovKeeper.Params.Set(ctx, govParams)
	if err != nil {
		tmos.Exit(err.Error())
	}

	if upgradeToTrigger != "" {
		upgradePlan := upgradetypes.Plan{
			Name:   upgradeToTrigger,
			Height: app.LastBlockHeight() + 10,
		}
		err = app.UpgradeKeeper.ScheduleUpgrade(ctx, upgradePlan)
		if err != nil {
			panic(err)
		}
	}
	return app
}
