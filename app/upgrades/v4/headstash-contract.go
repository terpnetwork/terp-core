package v4

import (
	"embed"
	"fmt"

	sdk "github.com/cosmos/cosmos-sdk/types"
	govtypes "github.com/cosmos/cosmos-sdk/x/gov/types"

	wasmkeeper "github.com/CosmWasm/wasmd/x/wasm/keeper"
	wasmtypes "github.com/CosmWasm/wasmd/x/wasm/types"
	"github.com/terpnetwork/terp-core/v4/app/keepers"
	"github.com/terpnetwork/terp-core/v4/app/upgrades"
)

//go:embed headstash_contract.wasm
var embedFs embed.FS

func setupHeadstashContract(ctx sdk.Context, keepers *keepers.AppKeepers) error {
	logger := ctx.Logger()
	// set the gov module address
	govModule := keepers.AccountKeeper.GetModuleAddress(govtypes.ModuleName)
	// define the headstash patch contract
	code, err := embedFs.ReadFile("headstash_contract.wasm")
	if err != nil {
		return err
	}
	// define instantiate permissions
	instantiateConfig := wasmtypes.AccessConfig{Permission: wasmtypes.AccessTypeEverybody}
	contractKeeper := wasmkeeper.NewDefaultPermissionKeeper(keepers.WasmKeeper)
	// store wasm contract
	codeID, _, err := contractKeeper.Create(ctx, govModule, code, &instantiateConfig)
	if err != nil {
		return err
	}
	// define claim_msg
	const claimMsg = "{wallet}"
	// define merkle_root string
	const merkleRoot = "77fb25152b72ac67f5a155461e396b0788dd0567ec32a96f8201b899ad516b02"
	// define instantiate msg
	initMsgBz := []byte(fmt.Sprintf(`{
		"owner":	"%s",
		"claim_msg_plaintext":	"%s",
		"merkle_root": 	"%s"
	}`,
		govModule, claimMsg, merkleRoot))
	// instantiate contract
	addr, _, err := contractKeeper.Instantiate(ctx, codeID, govModule, govModule, initMsgBz, "headstash patch contract", nil)
	if err != nil {
		return err
	}
	// format contract bytes to bech32 addr
	addrStr, err := sdk.Bech32ifyAddressBytes("terp", addr)
	if err != nil {
		return err
	}
	// print results
	logger.Info(fmt.Sprintf("instantiated headstash patch contract:  %s", addrStr))

	// define token denominations
	nativeDenom := upgrades.GetChainsDenomToken(ctx.ChainID())
	nativeFeeDenom := upgrades.GetChainsFeeDenomToken(ctx.ChainID())

	// define total amount of tokens per each denom
	amount := int64(123456789)
	terpcoins := sdk.NewCoins(
		sdk.NewInt64Coin(nativeDenom, amount),
	)
	thiolcoins := sdk.NewCoins(
		sdk.NewInt64Coin(nativeFeeDenom, amount),
	)
	// send tokens from gov module to headstash-contract
	if err := keepers.DistrKeeper.DistributeFromFeePool(ctx, terpcoins, addr); err != nil {
		panic(err)
	}
	if err := keepers.DistrKeeper.DistributeFromFeePool(ctx, thiolcoins, addr); err != nil {
		panic(err)
	}
	return nil
}
