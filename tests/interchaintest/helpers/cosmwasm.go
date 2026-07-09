package helpers

import (
	"context"
	"testing"

	"github.com/cosmos/cosmos-sdk/crypto/keyring"
	"github.com/strangelove-ventures/interchaintest/v10/chain/cosmos"
	"github.com/strangelove-ventures/interchaintest/v10/ibc"
	"github.com/strangelove-ventures/interchaintest/v10/testutil"
	"github.com/stretchr/testify/require"
)

func SetupContractWithVk(t *testing.T, ctx context.Context, chain *cosmos.CosmosChain, user ibc.Wallet, wasmFileLoc, vkFileLoc string, storeOnly bool, message string) (codeId, contract string) {
	StoreWasmWithVkWithFee(t, ctx, chain, user, wasmFileLoc, vkFileLoc, "", chain.Config().Denom)

	if !storeOnly {
		contractAddr, err := chain.InstantiateContract(ctx, user.KeyName(), codeId, message, true)
		if err != nil {
			t.Fatal(err)
		}
		return codeId, contractAddr
	}
	return codeId, ""
}

func SetupContract(t *testing.T, ctx context.Context, chain *cosmos.CosmosChain, keyname string, fileLoc string, storeOnly bool, message string) (codeId, contract string) {
	codeId, err := chain.StoreContract(ctx, keyname, fileLoc)
	if err != nil {
		t.Fatal(err)
	}

	if !storeOnly {
		contractAddr, err := chain.InstantiateContract(ctx, keyname, codeId, message, true)
		if err != nil {
			t.Fatal(err)
		}
		return codeId, contractAddr
	}
	return codeId, ""
}

func ExecuteMsgWithAmount(t *testing.T, ctx context.Context, chain *cosmos.CosmosChain, user ibc.Wallet, contractAddr, amount, message string) string {
	// amount is #utoken

	// There has to be a way to do this in ictest?
	cmd := []string{
		"terpd", "tx", "wasm", "execute", contractAddr, message,
		"--node", chain.GetRPCAddress(),
		"--home", chain.HomeDir(),
		"--chain-id", chain.Config().ChainID,
		"--from", user.KeyName(),
		"--gas", "500000",
		"--amount", amount,
		"--keyring-dir", chain.HomeDir(),
		"--keyring-backend", keyring.BackendTest,
		"-y",
	}
	stdout, _, err := chain.Exec(ctx, cmd, nil)
	require.NoError(t, err)

	debugOutput(t, string(stdout))

	if err := testutil.WaitForBlocks(ctx, 2, chain); err != nil {
		t.Fatal(err)
	}
	return string(stdout)
}

func ExecuteMsgWithFee(t *testing.T, ctx context.Context, chain *cosmos.CosmosChain, user ibc.Wallet, contractAddr, amount, feeCoin, message string) string {
	// amount is #utoken

	// There has to be a way to do this in ictest?
	cmd := []string{
		"terpd", "tx", "wasm", "execute", contractAddr, message,
		"--node", chain.GetRPCAddress(),
		"--home", chain.HomeDir(),
		"--chain-id", chain.Config().ChainID,
		"--from", user.KeyName(),
		"--gas", "500000",
		"--fees", feeCoin,
		"--keyring-dir", chain.HomeDir(),
		"--keyring-backend", keyring.BackendTest,
		"-y",
	}

	if amount != "" {
		cmd = append(cmd, "--amount", amount)
	}

	stdout, _, err := chain.Exec(ctx, cmd, nil)
	require.NoError(t, err)

	debugOutput(t, string(stdout))

	if err := testutil.WaitForBlocks(ctx, 2, chain); err != nil {
		t.Fatal(err)
	}
	return string(stdout)
}
func StoreWasmWithVkWithFee(t *testing.T, ctx context.Context, chain *cosmos.CosmosChain, user ibc.Wallet, wasmFileLoc, vkFileLoc, amount, feeCoin string) string {
	// amount is #utoken

	// There has to be a way to do this in ictest?
	cmd := []string{
		"terpd", "tx", "wasm", "headstash", wasmFileLoc, vkFileLoc,
		"--node", chain.GetRPCAddress(),
		"--home", chain.HomeDir(),
		"--chain-id", chain.Config().ChainID,
		"--from", user.KeyName(),
		"--gas", "200000",
		"--fees", feeCoin,
		"--keyring-dir", chain.HomeDir(),
		"--keyring-backend", keyring.BackendTest,
		"-y",
	}

	if amount != "" {
		cmd = append(cmd, "--amount", amount)
	}

	stdout, _, err := chain.Exec(ctx, cmd, nil)
	require.NoError(t, err)

	debugOutput(t, string(stdout))

	if err := testutil.WaitForBlocks(ctx, 2, chain); err != nil {
		t.Fatal(err)
	}
	return string(stdout)
}
