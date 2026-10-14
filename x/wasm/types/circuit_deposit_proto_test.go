package types

import (
	"testing"

	"github.com/cosmos/gogoproto/proto"
	"github.com/stretchr/testify/require"

	"github.com/cosmos/cosmos-sdk/codec/unknownproto"
)

func TestMsgPayCircuitDepositHasOwnDescriptor(t *testing.T) {
	msg := &MsgPayCircuitDeposit{
		Sender: "terp1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq2z8g3m",
		Years:  1,
	}
	bz, err := msg.Marshal()
	require.NoError(t, err)
	require.NoError(t, unknownproto.RejectUnknownFieldsStrict(bz, msg, unknownproto.DefaultAnyResolver{}))

	_, path := (*MsgPayCircuitDeposit)(nil).Descriptor()
	require.Equal(t, []int{0}, path)
	_, respPath := (*MsgPayCircuitDepositResponse)(nil).Descriptor()
	require.Equal(t, []int{1}, respPath)

	_, err = proto.HybridResolver.FindDescriptorByName("cosmwasm.wasm.v1.CircuitDeposit.PayCircuitDeposit")
	require.NoError(t, err)

	resp := &MsgPayCircuitDepositResponse{PaidUntilUnix: 1_700_000_000}
	require.Positive(t, resp.XXX_Size())
	rb, err := resp.Marshal()
	require.NoError(t, err)
	require.NoError(t, unknownproto.RejectUnknownFieldsStrict(rb, resp, unknownproto.DefaultAnyResolver{}))
}
