package keeper_test

import (
	"context"
	"testing"

	keepertest "github.com/terpnetwork/terp-core/testutil/keeper"
	"github.com/terpnetwork/terp-core/x/terp/keeper"
	"github.com/terpnetwork/terp-core/x/terp/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
)

func setupMsgServer(t testing.TB) (types.MsgServer, context.Context) {
	k, ctx := keepertest.TerpKeeper(t)
	return keeper.NewMsgServerImpl(*k), sdk.WrapSDKContext(ctx)
}
