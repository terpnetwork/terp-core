package types

import (
	context "context"

	grpc1 "github.com/cosmos/gogoproto/grpc"
	grpc "google.golang.org/grpc"
	codes "google.golang.org/grpc/codes"
	status "google.golang.org/grpc/status"
)

type CircuitDepositMsgServer interface {
	PayCircuitDeposit(context.Context, *MsgPayCircuitDeposit) (*MsgPayCircuitDepositResponse, error)
}

func RegisterCircuitDepositMsgServer(s grpc1.Server, srv CircuitDepositMsgServer) {
	s.RegisterService(&_CircuitDeposit_serviceDesc, srv)
}

func _CircuitDeposit_Pay_Handler(srv interface{}, ctx context.Context, dec func(interface{}) error, interceptor grpc.UnaryServerInterceptor) (interface{}, error) {
	in := new(MsgPayCircuitDeposit)
	if err := dec(in); err != nil {
		return nil, err
	}
	if interceptor == nil {
		return srv.(CircuitDepositMsgServer).PayCircuitDeposit(ctx, in)
	}
	info := &grpc.UnaryServerInfo{Server: srv, FullMethod: "/cosmwasm.wasm.v1.CircuitDeposit/PayCircuitDeposit"}
	handler := func(ctx context.Context, req interface{}) (interface{}, error) {
		return srv.(CircuitDepositMsgServer).PayCircuitDeposit(ctx, req.(*MsgPayCircuitDeposit))
	}
	return interceptor(ctx, in, info, handler)
}

var _CircuitDeposit_serviceDesc = grpc.ServiceDesc{
	ServiceName: "cosmwasm.wasm.v1.CircuitDeposit",
	HandlerType: (*CircuitDepositMsgServer)(nil),
	Methods: []grpc.MethodDesc{
		{MethodName: "PayCircuitDeposit", Handler: _CircuitDeposit_Pay_Handler},
	},
	Streams:  []grpc.StreamDesc{},
	Metadata: "cosmwasm/wasm/v1/tx.proto",
}

func (*UnimplementedMsgServer) PayCircuitDeposit(context.Context, *MsgPayCircuitDeposit) (*MsgPayCircuitDepositResponse, error) {
	return nil, status.Errorf(codes.Unimplemented, "method PayCircuitDeposit not implemented")
}

type CircuitDepositQueryServer interface {
	Deposit(context.Context, *QueryCircuitDepositRequest) (*QueryCircuitDepositResponse, error)
}

type CircuitDepositQueryClient interface {
	Deposit(ctx context.Context, in *QueryCircuitDepositRequest, opts ...grpc.CallOption) (*QueryCircuitDepositResponse, error)
}

type circuitDepositQueryClient struct{ cc grpc1.ClientConn }

func NewCircuitDepositQueryClient(cc grpc1.ClientConn) CircuitDepositQueryClient {
	return &circuitDepositQueryClient{cc}
}

func (c *circuitDepositQueryClient) Deposit(ctx context.Context, in *QueryCircuitDepositRequest, opts ...grpc.CallOption) (*QueryCircuitDepositResponse, error) {
	out := new(QueryCircuitDepositResponse)
	if err := c.cc.Invoke(ctx, "/cosmwasm.wasm.v1.CircuitDepositQuery/Deposit", in, out, opts...); err != nil {
		return nil, err
	}
	return out, nil
}

func RegisterCircuitDepositQueryServer(s grpc1.Server, srv CircuitDepositQueryServer) {
	s.RegisterService(&_CircuitDepositQuery_serviceDesc, srv)
}

func _CircuitDepositQuery_Deposit_Handler(srv interface{}, ctx context.Context, dec func(interface{}) error, interceptor grpc.UnaryServerInterceptor) (interface{}, error) {
	in := new(QueryCircuitDepositRequest)
	if err := dec(in); err != nil {
		return nil, err
	}
	if interceptor == nil {
		return srv.(CircuitDepositQueryServer).Deposit(ctx, in)
	}
	info := &grpc.UnaryServerInfo{Server: srv, FullMethod: "/cosmwasm.wasm.v1.CircuitDepositQuery/Deposit"}
	handler := func(ctx context.Context, req interface{}) (interface{}, error) {
		return srv.(CircuitDepositQueryServer).Deposit(ctx, req.(*QueryCircuitDepositRequest))
	}
	return interceptor(ctx, in, info, handler)
}

var _CircuitDepositQuery_serviceDesc = grpc.ServiceDesc{
	ServiceName: "cosmwasm.wasm.v1.CircuitDepositQuery",
	HandlerType: (*CircuitDepositQueryServer)(nil),
	Methods: []grpc.MethodDesc{
		{MethodName: "Deposit", Handler: _CircuitDepositQuery_Deposit_Handler},
	},
	Streams:  []grpc.StreamDesc{},
	Metadata: "cosmwasm/wasm/v1/query.proto",
}
