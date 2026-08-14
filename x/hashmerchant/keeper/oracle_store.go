package keeper

import (
	"context"
	"encoding/json"

	sdk "github.com/cosmos/cosmos-sdk/types"

	"github.com/terpnetwork/terp-core/v6/x/hashmerchant/types"
)

var oracleSourcesKeyPrefix = []byte{0x06}

func oracleSourcesKey(chainUID string) []byte {
	return append(append([]byte{}, oracleSourcesKeyPrefix...), []byte(chainUID)...)
}

// SetOracleSources stores modular oracle sources for a chain_uid.
func (k Keeper) SetOracleSources(ctx context.Context, chainUID string, sources []types.OracleSource) error {
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	bz, err := json.Marshal(sources)
	if err != nil {
		return err
	}
	sdkCtx.KVStore(k.storeKey).Set(oracleSourcesKey(chainUID), bz)
	return nil
}

// GetOracleSources returns registered oracle sources for a chain_uid.
func (k Keeper) GetOracleSources(ctx context.Context, chainUID string) ([]types.OracleSource, error) {
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	bz := sdkCtx.KVStore(k.storeKey).Get(oracleSourcesKey(chainUID))
	if bz == nil {
		return nil, nil
	}
	var sources []types.OracleSource
	if err := json.Unmarshal(bz, &sources); err != nil {
		return nil, err
	}
	return sources, nil
}