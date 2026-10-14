package keeper

import (
	"errors"
	"fmt"
	"reflect"
	"testing"

	wasmvmtypes "github.com/CosmWasm/wasmvm/v3/types"
	abci "github.com/cometbft/cometbft/abci/types"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"cosmossdk.io/log/v2"
	storetypes "github.com/cosmos/cosmos-sdk/store/v2/types"

	codectypes "github.com/cosmos/cosmos-sdk/codec/types"
	sdk "github.com/cosmos/cosmos-sdk/types"

	"github.com/terpnetwork/terp-core/v6/x/wasm/keeper/wasmtesting"
	"github.com/terpnetwork/terp-core/v6/x/wasm/types"
)

func TestDispatchSubmessages(t *testing.T) {
	noReplyCalled := &mockReplyer{}
	var anyGasLimit uint64 = 1
	specs := map[string]struct {
		msgs       []wasmvmtypes.SubMsg
		replyer    *mockReplyer
		msgHandler *wasmtesting.MockMessageHandler
		expErr     bool
		expData    []byte
		expCommits []bool
		expEvents  sdk.Events
	}{
		"no reply on error without error": {
			msgs:    []wasmvmtypes.SubMsg{{ReplyOn: wasmvmtypes.ReplyError}},
			replyer: noReplyCalled,
			msgHandler: &wasmtesting.MockMessageHandler{
				DispatchMsgFn: func(ctx sdk.Context, contractAddr sdk.AccAddress, contractIBCPortID string, msg wasmvmtypes.CosmosMsg) (events []sdk.Event, data [][]byte, msgResponses [][]*codectypes.Any, err error) {
					return nil, [][]byte{[]byte("myData")}, [][]*codectypes.Any{}, nil
				},
			},
			expCommits: []bool{true},
		},
		"no reply on success without success": {
			msgs:    []wasmvmtypes.SubMsg{{ReplyOn: wasmvmtypes.ReplySuccess}},
			replyer: noReplyCalled,
			msgHandler: &wasmtesting.MockMessageHandler{
				DispatchMsgFn: func(ctx sdk.Context, contractAddr sdk.AccAddress, contractIBCPortID string, msg wasmvmtypes.CosmosMsg) (events []sdk.Event, data [][]byte, msgResponses [][]*codectypes.Any, err error) {
					return nil, nil, [][]*codectypes.Any{}, errors.New("test, ignore")
				},
			},
			expCommits: []bool{false},
			expErr:     true,
		},
		"reply on success - received": {
			msgs: []wasmvmtypes.SubMsg{{
				ReplyOn: wasmvmtypes.ReplySuccess,
			}},
			replyer: &mockReplyer{
				replyFn: func(ctx sdk.Context, contractAddress sdk.AccAddress, reply wasmvmtypes.Reply) ([]byte, error) {
					return []byte("myReplyData"), nil
				},
			},
			msgHandler: &wasmtesting.MockMessageHandler{
				DispatchMsgFn: func(ctx sdk.Context, contractAddr sdk.AccAddress, contractIBCPortID string, msg wasmvmtypes.CosmosMsg) (events []sdk.Event, data [][]byte, msgResponses [][]*codectypes.Any, err error) {
					return nil, [][]byte{[]byte("myData")}, [][]*codectypes.Any{}, nil
				},
			},
			expData:    []byte("myReplyData"),
			expCommits: []bool{true},
		},
		"reply on error - handled": {
			msgs: []wasmvmtypes.SubMsg{{
				ReplyOn: wasmvmtypes.ReplyError,
			}},
			replyer: &mockReplyer{
				replyFn: func(ctx sdk.Context, contractAddress sdk.AccAddress, reply wasmvmtypes.Reply) ([]byte, error) {
					return []byte("myReplyData"), nil
				},
			},
			msgHandler: &wasmtesting.MockMessageHandler{
				DispatchMsgFn: func(ctx sdk.Context, contractAddr sdk.AccAddress, contractIBCPortID string, msg wasmvmtypes.CosmosMsg) (events []sdk.Event, data [][]byte, msgResponses [][]*codectypes.Any, err error) {
					return nil, nil, [][]*codectypes.Any{}, errors.New("my error")
				},
			},
			expData:    []byte("myReplyData"),
			expCommits: []bool{false},
		},
		"with reply events": {
			msgs: []wasmvmtypes.SubMsg{{
				ReplyOn: wasmvmtypes.ReplySuccess,
			}},
			replyer: &mockReplyer{
				replyFn: func(ctx sdk.Context, contractAddress sdk.AccAddress, reply wasmvmtypes.Reply) ([]byte, error) {
					ctx.EventManager().EmitEvent(sdk.NewEvent("wasm-reply"))
					return []byte("myReplyData"), nil
				},
			},
			msgHandler: &wasmtesting.MockMessageHandler{
				DispatchMsgFn: func(ctx sdk.Context, contractAddr sdk.AccAddress, contractIBCPortID string, msg wasmvmtypes.CosmosMsg) (events []sdk.Event, data [][]byte, msgResponses [][]*codectypes.Any, err error) {
					myEvents := []sdk.Event{{Type: "myEvent", Attributes: []abci.EventAttribute{{Key: "foo", Value: "bar"}}}}
					return myEvents, [][]byte{[]byte("myData")}, [][]*codectypes.Any{}, nil
				},
			},
			expData:    []byte("myReplyData"),
			expCommits: []bool{true},
			expEvents: []sdk.Event{
				{
					Type:       "myEvent",
					Attributes: []abci.EventAttribute{{Key: "foo", Value: "bar"}},
				},
				sdk.NewEvent("wasm-reply"),
			},
		},
		"with context events - released on commit": {
			msgs: []wasmvmtypes.SubMsg{{
				ReplyOn: wasmvmtypes.ReplyNever,
			}},
			replyer: &mockReplyer{},
			msgHandler: &wasmtesting.MockMessageHandler{
				DispatchMsgFn: func(ctx sdk.Context, contractAddr sdk.AccAddress, contractIBCPortID string, msg wasmvmtypes.CosmosMsg) (events []sdk.Event, data [][]byte, msgResponses [][]*codectypes.Any, err error) {
					myEvents := []sdk.Event{{Type: "myEvent", Attributes: []abci.EventAttribute{{Key: "foo", Value: "bar"}}}}
					ctx.EventManager().EmitEvents(myEvents)
					return nil, nil, [][]*codectypes.Any{}, nil
				},
			},
			expCommits: []bool{true},
			expEvents: []sdk.Event{{
				Type:       "myEvent",
				Attributes: []abci.EventAttribute{{Key: "foo", Value: "bar"}},
			}},
		},
		"with context events - discarded on failure": {
			msgs: []wasmvmtypes.SubMsg{{
				ReplyOn: wasmvmtypes.ReplyNever,
			}},
			replyer: &mockReplyer{},
			msgHandler: &wasmtesting.MockMessageHandler{
				DispatchMsgFn: func(ctx sdk.Context, contractAddr sdk.AccAddress, contractIBCPortID string, msg wasmvmtypes.CosmosMsg) (events []sdk.Event, data [][]byte, msgResponses [][]*codectypes.Any, err error) {
					myEvents := []sdk.Event{{Type: "myEvent", Attributes: []abci.EventAttribute{{Key: "foo", Value: "bar"}}}}
					ctx.EventManager().EmitEvents(myEvents)
					return nil, nil, [][]*codectypes.Any{}, errors.New("testing")
				},
			},
			expCommits: []bool{false},
			expErr:     true,
		},
		"reply returns error": {
			msgs: []wasmvmtypes.SubMsg{{
				ReplyOn: wasmvmtypes.ReplySuccess,
			}},
			replyer: &mockReplyer{
				replyFn: func(ctx sdk.Context, contractAddress sdk.AccAddress, reply wasmvmtypes.Reply) ([]byte, error) {
					return nil, errors.New("reply failed")
				},
			},
			msgHandler: &wasmtesting.MockMessageHandler{
				DispatchMsgFn: func(ctx sdk.Context, contractAddr sdk.AccAddress, contractIBCPortID string, msg wasmvmtypes.CosmosMsg) (events []sdk.Event, data [][]byte, msgResponses [][]*codectypes.Any, err error) {
					return nil, nil, [][]*codectypes.Any{}, nil
				},
			},
			expCommits: []bool{false},
			expErr:     true,
		},
		"with gas limit - out of gas": {
			msgs: []wasmvmtypes.SubMsg{{
				GasLimit: &anyGasLimit,
				ReplyOn:  wasmvmtypes.ReplyError,
			}},
			replyer: &mockReplyer{
				replyFn: func(ctx sdk.Context, contractAddress sdk.AccAddress, reply wasmvmtypes.Reply) ([]byte, error) {
					return []byte("myReplyData"), nil
				},
			},
			msgHandler: &wasmtesting.MockMessageHandler{
				DispatchMsgFn: func(ctx sdk.Context, contractAddr sdk.AccAddress, contractIBCPortID string, msg wasmvmtypes.CosmosMsg) (events []sdk.Event, data [][]byte, msgResponses [][]*codectypes.Any, err error) {
					ctx.GasMeter().ConsumeGas(storetypes.Gas(101), "testing")
					return nil, [][]byte{[]byte("someData")}, [][]*codectypes.Any{}, nil
				},
			},
			expData:    []byte("myReplyData"),
			expCommits: []bool{false},
		},
		"with gas limit - within limit no error": {
			msgs: []wasmvmtypes.SubMsg{{
				GasLimit: &anyGasLimit,
				ReplyOn:  wasmvmtypes.ReplyError,
			}},
			replyer: &mockReplyer{},
			msgHandler: &wasmtesting.MockMessageHandler{
				DispatchMsgFn: func(ctx sdk.Context, contractAddr sdk.AccAddress, contractIBCPortID string, msg wasmvmtypes.CosmosMsg) (events []sdk.Event, data [][]byte, msgResponses [][]*codectypes.Any, err error) {
					ctx.GasMeter().ConsumeGas(storetypes.Gas(1), "testing")
					return nil, [][]byte{[]byte("someData")}, [][]*codectypes.Any{}, nil
				},
			},
			expCommits: []bool{true},
		},
		"never reply - with nil response": {
			msgs:    []wasmvmtypes.SubMsg{{ID: 1, ReplyOn: wasmvmtypes.ReplyNever}, {ID: 2, ReplyOn: wasmvmtypes.ReplyNever}},
			replyer: &mockReplyer{},
			msgHandler: &wasmtesting.MockMessageHandler{
				DispatchMsgFn: func(ctx sdk.Context, contractAddr sdk.AccAddress, contractIBCPortID string, msg wasmvmtypes.CosmosMsg) (events []sdk.Event, data [][]byte, msgResponses [][]*codectypes.Any, err error) {
					return nil, [][]byte{nil}, [][]*codectypes.Any{}, nil
				},
			},
			expCommits: []bool{true, true},
		},
		"never reply - with any non nil response": {
			msgs:    []wasmvmtypes.SubMsg{{ID: 1, ReplyOn: wasmvmtypes.ReplyNever}, {ID: 2, ReplyOn: wasmvmtypes.ReplyNever}},
			replyer: &mockReplyer{},
			msgHandler: &wasmtesting.MockMessageHandler{
				DispatchMsgFn: func(ctx sdk.Context, contractAddr sdk.AccAddress, contractIBCPortID string, msg wasmvmtypes.CosmosMsg) (events []sdk.Event, data [][]byte, msgResponses [][]*codectypes.Any, err error) {
					return nil, [][]byte{{}}, [][]*codectypes.Any{}, nil
				},
			},
			expCommits: []bool{true, true},
		},
		"never reply - with error": {
			msgs:    []wasmvmtypes.SubMsg{{ID: 1, ReplyOn: wasmvmtypes.ReplyNever}, {ID: 2, ReplyOn: wasmvmtypes.ReplyNever}},
			replyer: &mockReplyer{},
			msgHandler: &wasmtesting.MockMessageHandler{
				DispatchMsgFn: func(ctx sdk.Context, contractAddr sdk.AccAddress, contractIBCPortID string, msg wasmvmtypes.CosmosMsg) (events []sdk.Event, data [][]byte, msgResponses [][]*codectypes.Any, err error) {
					return nil, [][]byte{{}}, [][]*codectypes.Any{}, errors.New("testing")
				},
			},
			expCommits: []bool{false, false},
			expErr:     true,
		},
		"multiple msg - last reply returned": {
			msgs: []wasmvmtypes.SubMsg{{ID: 1, ReplyOn: wasmvmtypes.ReplyError}, {ID: 2, ReplyOn: wasmvmtypes.ReplyError}},
			replyer: &mockReplyer{
				replyFn: func(ctx sdk.Context, contractAddress sdk.AccAddress, reply wasmvmtypes.Reply) ([]byte, error) {
					return []byte(fmt.Sprintf("myReplyData:%d", reply.ID)), nil
				},
			},
			msgHandler: &wasmtesting.MockMessageHandler{
				DispatchMsgFn: func(ctx sdk.Context, contractAddr sdk.AccAddress, contractIBCPortID string, msg wasmvmtypes.CosmosMsg) (events []sdk.Event, data [][]byte, msgResponses [][]*codectypes.Any, err error) {
					return nil, nil, [][]*codectypes.Any{}, errors.New("my error")
				},
			},
			expData:    []byte("myReplyData:2"),
			expCommits: []bool{false, false},
		},
		"multiple msg - last non nil reply returned": {
			msgs: []wasmvmtypes.SubMsg{{ID: 1, ReplyOn: wasmvmtypes.ReplyError}, {ID: 2, ReplyOn: wasmvmtypes.ReplyError}},
			replyer: &mockReplyer{
				replyFn: func(ctx sdk.Context, contractAddress sdk.AccAddress, reply wasmvmtypes.Reply) ([]byte, error) {
					if reply.ID == 2 {
						return nil, nil
					}
					return []byte("myReplyData:1"), nil
				},
			},
			msgHandler: &wasmtesting.MockMessageHandler{
				DispatchMsgFn: func(ctx sdk.Context, contractAddr sdk.AccAddress, contractIBCPortID string, msg wasmvmtypes.CosmosMsg) (events []sdk.Event, data [][]byte, msgResponses [][]*codectypes.Any, err error) {
					return nil, nil, [][]*codectypes.Any{}, errors.New("my error")
				},
			},
			expData:    []byte("myReplyData:1"),
			expCommits: []bool{false, false},
		},
		"multiple msg - empty reply can overwrite result": {
			msgs: []wasmvmtypes.SubMsg{{ID: 1, ReplyOn: wasmvmtypes.ReplyError}, {ID: 2, ReplyOn: wasmvmtypes.ReplyError}},
			replyer: &mockReplyer{
				replyFn: func(ctx sdk.Context, contractAddress sdk.AccAddress, reply wasmvmtypes.Reply) ([]byte, error) {
					if reply.ID == 2 {
						return []byte{}, nil
					}
					return []byte("myReplyData:1"), nil
				},
			},
			msgHandler: &wasmtesting.MockMessageHandler{
				DispatchMsgFn: func(ctx sdk.Context, contractAddr sdk.AccAddress, contractIBCPortID string, msg wasmvmtypes.CosmosMsg) (events []sdk.Event, data [][]byte, msgResponses [][]*codectypes.Any, err error) {
					return nil, nil, [][]*codectypes.Any{}, errors.New("my error")
				},
			},
			expData:    []byte{},
			expCommits: []bool{false, false},
		},
		"message event filtered without reply": {
			msgs: []wasmvmtypes.SubMsg{{
				ReplyOn: wasmvmtypes.ReplyNever,
			}},
			replyer: &mockReplyer{
				replyFn: func(ctx sdk.Context, contractAddress sdk.AccAddress, reply wasmvmtypes.Reply) ([]byte, error) {
					return nil, errors.New("should never be called")
				},
			},
			msgHandler: &wasmtesting.MockMessageHandler{
				DispatchMsgFn: func(ctx sdk.Context, contractAddr sdk.AccAddress, contractIBCPortID string, msg wasmvmtypes.CosmosMsg) (events []sdk.Event, data [][]byte, msgResponses [][]*codectypes.Any, err error) {
					myEvents := []sdk.Event{
						sdk.NewEvent("message"),
						sdk.NewEvent("execute", sdk.NewAttribute("foo", "bar")),
					}
					return myEvents, [][]byte{[]byte("myData")}, [][]*codectypes.Any{}, nil
				},
			},
			expData:    nil,
			expCommits: []bool{true},
			expEvents:  []sdk.Event{sdk.NewEvent("execute", sdk.NewAttribute("foo", "bar"))},
		},
		"wasm reply gets proper events": {
			// put fake wasmmsg in here to show where it comes from
			msgs: []wasmvmtypes.SubMsg{{ID: 1, ReplyOn: wasmvmtypes.ReplyAlways, Msg: wasmvmtypes.CosmosMsg{Wasm: &wasmvmtypes.WasmMsg{}}}},
			replyer: &mockReplyer{
				replyFn: func(ctx sdk.Context, contractAddress sdk.AccAddress, reply wasmvmtypes.Reply) ([]byte, error) {
					if reply.Result.Err != "" {
						return nil, errors.New(reply.Result.Err)
					}
					res := reply.Result.Ok

					// message is stripped; execute and wasm both reach the contract.
					if len(res.Events) != 2 {
						return nil, fmt.Errorf("event count: %#v", res.Events)
					}
					if res.Events[0].Type != "execute" {
						return nil, fmt.Errorf("event0: %#v", res.Events[0])
					}
					if res.Events[1].Type != "wasm" {
						return nil, fmt.Errorf("event1: %#v", res.Events[1])
					}

					// let's add a custom event here and see if it makes it out
					ctx.EventManager().EmitEvent(sdk.NewEvent("wasm-reply"))

					// update data from what we got in
					return res.Data, nil
				},
			},
			msgHandler: &wasmtesting.MockMessageHandler{
				DispatchMsgFn: func(ctx sdk.Context, contractAddr sdk.AccAddress, contractIBCPortID string, msg wasmvmtypes.CosmosMsg) (events []sdk.Event, data [][]byte, msgResponses [][]*codectypes.Any, err error) {
					events = []sdk.Event{
						sdk.NewEvent("message", sdk.NewAttribute("_contract_address", contractAddr.String())),
						// we don't know what the contractAddr will be so we can't use it in the final tests
						sdk.NewEvent("execute", sdk.NewAttribute("_contract_address", "placeholder-random-addr")),
						sdk.NewEvent("wasm", sdk.NewAttribute("random", "data")),
					}
					return events, [][]byte{[]byte("subData")}, [][]*codectypes.Any{}, nil
				},
			},
			expData:    []byte("subData"),
			expCommits: []bool{true},
			expEvents: []sdk.Event{
				sdk.NewEvent("execute", sdk.NewAttribute("_contract_address", "placeholder-random-addr")),
				sdk.NewEvent("wasm", sdk.NewAttribute("random", "data")),
				sdk.NewEvent("wasm-reply"),
			},
		},
		"wasm reply gets payload": {
			// put fake wasmmsg in here to show where it comes from
			msgs: []wasmvmtypes.SubMsg{{ID: 1, ReplyOn: wasmvmtypes.ReplyAlways, Payload: []byte("payloadData"), Msg: wasmvmtypes.CosmosMsg{Wasm: &wasmvmtypes.WasmMsg{}}}},
			replyer: &mockReplyer{
				replyFn: func(ctx sdk.Context, contractAddress sdk.AccAddress, reply wasmvmtypes.Reply) ([]byte, error) {
					if reply.Result.Err != "" {
						return nil, errors.New(reply.Result.Err)
					}

					// ensure we got the payload
					if !reflect.DeepEqual(reply.Payload, []byte("payloadData")) {
						return nil, fmt.Errorf("payload mismatch: %s != 'payloadData'", reply.Payload)
					}

					// update data from what we got in
					return reply.Result.Ok.Data, nil
				},
			},
			msgHandler: &wasmtesting.MockMessageHandler{
				DispatchMsgFn: func(ctx sdk.Context, contractAddr sdk.AccAddress, contractIBCPortID string, msg wasmvmtypes.CosmosMsg) (events []sdk.Event, data [][]byte, msgResponses [][]*codectypes.Any, err error) {
					return nil, nil, [][]*codectypes.Any{}, nil
				},
			},
			expCommits: []bool{true},
		},
		"wasm reply keeps host events and sorts attributes": {
			msgs: []wasmvmtypes.SubMsg{{ID: 1, ReplyOn: wasmvmtypes.ReplyAlways, Msg: wasmvmtypes.CosmosMsg{Wasm: &wasmvmtypes.WasmMsg{}}}},
			replyer: &mockReplyer{
				replyFn: func(ctx sdk.Context, contractAddress sdk.AccAddress, reply wasmvmtypes.Reply) ([]byte, error) {
					if reply.Result.Err != "" {
						return nil, errors.New(reply.Result.Err)
					}
					res := reply.Result.Ok
					want := []string{
						"transfer",
						types.EventTypeExecute,
						types.EventTypeInstantiate,
						types.EventTypeSudo,
						types.EventTypeReply,
						types.WasmModuleEventType,
						types.CustomContractEventPrefix + "custom",
					}
					if len(res.Events) != len(want) {
						return nil, fmt.Errorf("event count: %#v", res.Events)
					}
					for i, ev := range res.Events {
						if ev.Type != want[i] {
							return nil, fmt.Errorf("event %d: got %s want %s (%#v)", i, ev.Type, want[i], res.Events)
						}
						for j := 1; j < len(ev.Attributes); j++ {
							if ev.Attributes[j-1].Key > ev.Attributes[j].Key {
								return nil, fmt.Errorf("attributes not sorted: %#v", ev)
							}
						}
					}
					return res.Data, nil
				},
			},
			msgHandler: &wasmtesting.MockMessageHandler{
				DispatchMsgFn: func(ctx sdk.Context, contractAddr sdk.AccAddress, contractIBCPortID string, msg wasmvmtypes.CosmosMsg) (events []sdk.Event, data [][]byte, msgResponses [][]*codectypes.Any, err error) {
					ctx.EventManager().EmitEvent(sdk.NewEvent("transfer",
						sdk.NewAttribute("recipient", "cosmos1bankrecipient"),
						sdk.NewAttribute("sender", "cosmos1banksender"),
						sdk.NewAttribute("amount", "1utoken"),
					))
					events = []sdk.Event{
						sdk.NewEvent(types.EventTypeExecute, sdk.NewAttribute("_contract_address", "placeholder-random-addr")),
						sdk.NewEvent(types.EventTypeInstantiate, sdk.NewAttribute("_contract_address", "placeholder-random-addr")),
						sdk.NewEvent(types.EventTypeSudo, sdk.NewAttribute("_contract_address", "placeholder-random-addr")),
						sdk.NewEvent(types.EventTypeReply, sdk.NewAttribute("_contract_address", "placeholder-random-addr")),
						sdk.NewEvent(types.WasmModuleEventType, sdk.NewAttribute("random", "data")),
						sdk.NewEvent(types.CustomContractEventPrefix+"custom", sdk.NewAttribute("foo", "bar")),
					}
					return events, [][]byte{[]byte("subData")}, [][]*codectypes.Any{}, nil
				},
			},
			expData:    []byte("subData"),
			expCommits: []bool{true},
			expEvents: []sdk.Event{
				// Attribute sort runs on the shared slice after emit, so tx events are sorted too.
				sdk.NewEvent("transfer",
					sdk.NewAttribute("amount", "1utoken"),
					sdk.NewAttribute("recipient", "cosmos1bankrecipient"),
					sdk.NewAttribute("sender", "cosmos1banksender"),
				),
				sdk.NewEvent(types.EventTypeExecute, sdk.NewAttribute("_contract_address", "placeholder-random-addr")),
				sdk.NewEvent(types.EventTypeInstantiate, sdk.NewAttribute("_contract_address", "placeholder-random-addr")),
				sdk.NewEvent(types.EventTypeSudo, sdk.NewAttribute("_contract_address", "placeholder-random-addr")),
				sdk.NewEvent(types.EventTypeReply, sdk.NewAttribute("_contract_address", "placeholder-random-addr")),
				sdk.NewEvent(types.WasmModuleEventType, sdk.NewAttribute("random", "data")),
				sdk.NewEvent(types.CustomContractEventPrefix+"custom", sdk.NewAttribute("foo", "bar")),
			},
		},
		"non-wasm reply events get filtered": {
			// show events from a stargate message gets filtered out
			msgs: []wasmvmtypes.SubMsg{{ID: 1, ReplyOn: wasmvmtypes.ReplyAlways, Msg: wasmvmtypes.CosmosMsg{Any: &wasmvmtypes.AnyMsg{}}}},
			replyer: &mockReplyer{
				replyFn: func(ctx sdk.Context, contractAddress sdk.AccAddress, reply wasmvmtypes.Reply) ([]byte, error) {
					if reply.Result.Err != "" {
						return nil, errors.New(reply.Result.Err)
					}
					res := reply.Result.Ok

					// ensure the input events are what we expect
					// I didn't use require.Equal() to act more like a contract... but maybe that would be better
					if len(res.Events) != 0 {
						return nil, errors.New("events not filtered out")
					}

					// let's add a custom event here and see if it makes it out
					ctx.EventManager().EmitEvent(sdk.NewEvent("stargate-reply"))

					// update data from what we got in
					return res.Data, nil
				},
			},
			msgHandler: &wasmtesting.MockMessageHandler{
				DispatchMsgFn: func(ctx sdk.Context, contractAddr sdk.AccAddress, contractIBCPortID string, msg wasmvmtypes.CosmosMsg) (events []sdk.Event, data [][]byte, msgResponses [][]*codectypes.Any, err error) {
					events = []sdk.Event{
						// this is filtered out
						sdk.NewEvent("message", sdk.NewAttribute("stargate", "something-something")),
						// we still emit this to the client, but not the contract
						sdk.NewEvent("non-deterministic"),
					}
					return events, [][]byte{[]byte("subData")}, [][]*codectypes.Any{}, nil
				},
			},
			expData:    []byte("subData"),
			expCommits: []bool{true},
			expEvents: []sdk.Event{
				sdk.NewEvent("non-deterministic"),
				// the event from reply is also exposed
				sdk.NewEvent("stargate-reply"),
			},
		},
	}
	for name, spec := range specs {
		t.Run(name, func(t *testing.T) {
			var mockStore wasmtesting.MockCommitMultiStore
			em := sdk.NewEventManager()
			ctx := sdk.Context{}.WithMultiStore(&mockStore).
				WithGasMeter(storetypes.NewGasMeter(100)).
				WithEventManager(em).WithLogger(log.NewTestLogger(t))
			d := NewMessageDispatcher(spec.msgHandler, spec.replyer)

			// run the test
			gotData, gotErr := d.DispatchSubmessages(ctx, RandomAccountAddress(t), "any_port", spec.msgs)
			if spec.expErr {
				require.Error(t, gotErr)
				assert.Empty(t, em.Events())
				return
			}

			// if we don't expect an error, we should get no error
			require.NoError(t, gotErr)
			assert.Equal(t, spec.expData, gotData)

			// ensure the commits are what we expect
			assert.Equal(t, spec.expCommits, mockStore.Committed)
			if len(spec.expEvents) == 0 {
				assert.Empty(t, em.Events())
			} else {
				assert.Equal(t, spec.expEvents, em.Events())
			}
		})
	}
}

func TestDispatchSubmessagesNativeReplyOmitsSDKEvents(t *testing.T) {
	bankEvent := sdk.NewEvent("transfer",
		sdk.NewAttribute("recipient", "cosmos1bankrecipientxxxxxxxxxxxxxxxxxxxxxxxx"),
		sdk.NewAttribute("sender", "cosmos1banksenderxxxxxxxxxxxxxxxxxxxxxxxxxx"),
		sdk.NewAttribute("amount", "1000000000000000000utoken"),
	)

	dispatch := func(wasmMsg bool, emitBank bool) (sdk.Events, wasmvmtypes.Reply) {
		t.Helper()
		var captured wasmvmtypes.Reply
		replyer := &mockReplyer{
			replyFn: func(ctx sdk.Context, contractAddress sdk.AccAddress, reply wasmvmtypes.Reply) ([]byte, error) {
				captured = reply
				return []byte("myReplyData"), nil
			},
		}
		msgHandler := &wasmtesting.MockMessageHandler{
			DispatchMsgFn: func(ctx sdk.Context, contractAddr sdk.AccAddress, contractIBCPortID string, msg wasmvmtypes.CosmosMsg) (events []sdk.Event, data [][]byte, msgResponses [][]*codectypes.Any, err error) {
				if emitBank {
					ctx.EventManager().EmitEvent(bankEvent)
				}
				return []sdk.Event{
					sdk.NewEvent("message", sdk.NewAttribute(types.AttributeKeyContractAddr, contractAddr.String())),
					sdk.NewEvent(types.EventTypeInstantiate, sdk.NewAttribute(types.AttributeKeyContractAddr, "cosmos1child")),
					sdk.NewEvent(types.WasmModuleEventType, sdk.NewAttribute("random", "data")),
				}, [][]byte{[]byte("subData")}, [][]*codectypes.Any{}, nil
			},
		}
		em := sdk.NewEventManager()
		var mockStore wasmtesting.MockCommitMultiStore
		ctx := sdk.Context{}.WithMultiStore(&mockStore).
			WithGasMeter(storetypes.NewGasMeter(100)).
			WithEventManager(em).WithLogger(log.NewTestLogger(t))
		d := NewMessageDispatcher(msgHandler, replyer)
		msg := wasmvmtypes.CosmosMsg{Any: &wasmvmtypes.AnyMsg{}}
		if wasmMsg {
			msg = wasmvmtypes.CosmosMsg{Wasm: &wasmvmtypes.WasmMsg{}}
		}
		msgs := []wasmvmtypes.SubMsg{{
			ID:      1,
			ReplyOn: wasmvmtypes.ReplyAlways,
			Msg:     msg,
		}}
		gotData, err := d.DispatchSubmessages(ctx, RandomAccountAddress(t), "any_port", msgs)
		require.NoError(t, err)
		assert.Equal(t, []byte("myReplyData"), gotData)
		require.NotNil(t, captured.Result.Ok)
		return em.Events(), captured
	}

	gasReg := types.NewDefaultWasmGasRegister()

	// wasmd #917: a native submessage's SDK events stay on the tx and out of reply.
	// ReplyCosts does not see them. GasUsed stays 0. That patch stays.
	emittedNative, replyNative := dispatch(false, true)
	_, replyNativeQuiet := dispatch(false, false)
	require.Empty(t, replyNative.Result.Ok.Events)
	require.Empty(t, replyNativeQuiet.Result.Ok.Events)
	assert.Equal(t, []byte("subData"), replyNative.Result.Ok.Data)
	assert.Zero(t, replyNative.GasUsed)
	assert.Zero(t, replyNativeQuiet.GasUsed)
	require.NotEmpty(t, emittedNative)
	assert.Equal(t, "transfer", emittedNative[0].Type)
	for _, ev := range emittedNative {
		assert.NotEqual(t, "message", ev.Type)
	}
	assert.Equal(t, gasReg.ReplyCosts(true, replyNativeQuiet), gasReg.ReplyCosts(true, replyNative))

	// Wasm submessages keep instantiate, contract events, and events the sub-context emitted.
	// "message" is still dropped. Dropping instantiate or wasm fails this check.
	_, replyWasmQuiet := dispatch(true, false)
	emittedWasm, replyWasm := dispatch(true, true)
	assert.Zero(t, replyWasm.GasUsed)
	assert.Equal(t, []byte("subData"), replyWasm.Result.Ok.Data)
	require.Len(t, replyWasmQuiet.Result.Ok.Events, 2)
	assert.Equal(t, types.EventTypeInstantiate, replyWasmQuiet.Result.Ok.Events[0].Type)
	assert.Equal(t, types.AttributeKeyContractAddr, replyWasmQuiet.Result.Ok.Events[0].Attributes[0].Key)
	assert.Equal(t, "cosmos1child", replyWasmQuiet.Result.Ok.Events[0].Attributes[0].Value)
	assert.Equal(t, types.WasmModuleEventType, replyWasmQuiet.Result.Ok.Events[1].Type)
	require.Len(t, replyWasm.Result.Ok.Events, 3)
	assert.Equal(t, "transfer", replyWasm.Result.Ok.Events[0].Type)
	transferAttrs := replyWasm.Result.Ok.Events[0].Attributes
	require.Len(t, transferAttrs, 3)
	assert.Equal(t, "amount", transferAttrs[0].Key)
	assert.Equal(t, "1000000000000000000utoken", transferAttrs[0].Value)
	assert.Equal(t, "recipient", transferAttrs[1].Key)
	assert.Equal(t, "sender", transferAttrs[2].Key)
	assert.Equal(t, types.EventTypeInstantiate, replyWasm.Result.Ok.Events[1].Type)
	assert.Equal(t, types.WasmModuleEventType, replyWasm.Result.Ok.Events[2].Type)
	for _, ev := range replyWasm.Result.Ok.Events {
		assert.NotEqual(t, "message", ev.Type)
	}
	assert.Equal(t, "transfer", emittedWasm[0].Type)
	txAttrs := sdkAttributesToWasmVMAttributes(emittedWasm[0].Attributes)
	require.Len(t, txAttrs, len(transferAttrs))
	for i := range txAttrs {
		assert.Equal(t, txAttrs[i].Key, transferAttrs[i].Key)
		assert.Equal(t, txAttrs[i].Value, transferAttrs[i].Value)
	}
	assert.Greater(t, gasReg.ReplyCosts(true, replyWasm), gasReg.ReplyCosts(true, replyWasmQuiet))
}

type mockReplyer struct {
	replyFn func(ctx sdk.Context, contractAddress sdk.AccAddress, reply wasmvmtypes.Reply) ([]byte, error)
}

func (m mockReplyer) reply(ctx sdk.Context, contractAddress sdk.AccAddress, reply wasmvmtypes.Reply) ([]byte, error) {
	if m.replyFn == nil {
		panic("not expected to be called")
	}
	return m.replyFn(ctx, contractAddress, reply)
}
