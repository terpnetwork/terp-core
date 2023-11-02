package helpers

import (
	"context"
	"testing"

	"github.com/strangelove-ventures/interchaintest/v7/chain/cosmos"
	"github.com/stretchr/testify/require"
)

func GetUserTokenFactoryBalances(t *testing.T, ctx context.Context, chain *cosmos.CosmosChain, contract string, uaddr string) GetAllBalancesResponse {
	var res GetAllBalancesResponse
	err := chain.QueryContract(ctx, contract, QueryMsg{GetAllBalances: &GetAllBalancesQuery{Address: uaddr}}, &res)
	require.NoError(t, err)
	return res
}

func GetClockContractValue(t *testing.T, ctx context.Context, chain *cosmos.CosmosChain, contract string) ClockContractResponse {
	var res ClockContractResponse
	err := chain.QueryContract(ctx, contract, QueryMsg{GetConfig: &struct{}{}}, &res)
	require.NoError(t, err)
	return res
}
