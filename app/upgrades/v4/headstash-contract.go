package v4

import (
	"embed"
	"fmt"

	sdk "github.com/cosmos/cosmos-sdk/types"
	govtypes "github.com/cosmos/cosmos-sdk/x/gov/types"

	wasmkeeper "github.com/CosmWasm/wasmd/x/wasm/keeper"
	wasmtypes "github.com/CosmWasm/wasmd/x/wasm/types"
	"github.com/terpnetwork/terp-core/v2/app/keepers"
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
	instantiateConfig := wasmtypes.AccessConfig{Permission: wasmtypes.AccessTypeNobody}
	contractKeeper := wasmkeeper.NewDefaultPermissionKeeper(keepers.WasmKeeper)
	// store wasm contract
	codeID, _, err := contractKeeper.Create(ctx, govModule, code, &instantiateConfig)
	if err != nil {
		return err
	}
	// define instantiate msg
	initMsgBz := []byte(fmt.Sprintf(`{
		"owner":	"%s",
		"claim_msg_plaintext":	"%s"
	}`,
		govModule, "{address}"))
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
	logger.Info(fmt.Sprintf("instatiated headstash patch contract:  %s", addrStr))

	return nil
}
