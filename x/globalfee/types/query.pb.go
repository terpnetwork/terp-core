// Code generated by protoc-gen-gogo. DO NOT EDIT.
// source: gaia/globalfee/v1beta1/query.proto

package types

import (
	context "context"
	fmt "fmt"
	github_com_cosmos_cosmos_sdk_types "github.com/cosmos/cosmos-sdk/types"
	types "github.com/cosmos/cosmos-sdk/types"
	_ "github.com/cosmos/gogoproto/gogoproto"
	grpc1 "github.com/cosmos/gogoproto/grpc"
	proto "github.com/cosmos/gogoproto/proto"
	_ "google.golang.org/genproto/googleapis/api/annotations"
	grpc "google.golang.org/grpc"
	codes "google.golang.org/grpc/codes"
	status "google.golang.org/grpc/status"
	io "io"
	math "math"
	math_bits "math/bits"
)

// Reference imports to suppress errors if they are not otherwise used.
var _ = proto.Marshal
var _ = fmt.Errorf
var _ = math.Inf

// This is a compile-time assertion to ensure that this generated file
// is compatible with the proto package it is being compiled against.
// A compilation error at this line likely means your copy of the
// proto package needs to be updated.
const _ = proto.GoGoProtoPackageIsVersion3 // please upgrade the proto package

// QueryMinimumGasPricesRequest is the request type for the
// Query/MinimumGasPrices RPC method.
type QueryMinimumGasPricesRequest struct {
}

func (m *QueryMinimumGasPricesRequest) Reset()         { *m = QueryMinimumGasPricesRequest{} }
func (m *QueryMinimumGasPricesRequest) String() string { return proto.CompactTextString(m) }
func (*QueryMinimumGasPricesRequest) ProtoMessage()    {}
func (*QueryMinimumGasPricesRequest) Descriptor() ([]byte, []int) {
	return fileDescriptor_12a736cede25d10a, []int{0}
}
func (m *QueryMinimumGasPricesRequest) XXX_Unmarshal(b []byte) error {
	return m.Unmarshal(b)
}
func (m *QueryMinimumGasPricesRequest) XXX_Marshal(b []byte, deterministic bool) ([]byte, error) {
	if deterministic {
		return xxx_messageInfo_QueryMinimumGasPricesRequest.Marshal(b, m, deterministic)
	} else {
		b = b[:cap(b)]
		n, err := m.MarshalToSizedBuffer(b)
		if err != nil {
			return nil, err
		}
		return b[:n], nil
	}
}
func (m *QueryMinimumGasPricesRequest) XXX_Merge(src proto.Message) {
	xxx_messageInfo_QueryMinimumGasPricesRequest.Merge(m, src)
}
func (m *QueryMinimumGasPricesRequest) XXX_Size() int {
	return m.Size()
}
func (m *QueryMinimumGasPricesRequest) XXX_DiscardUnknown() {
	xxx_messageInfo_QueryMinimumGasPricesRequest.DiscardUnknown(m)
}

var xxx_messageInfo_QueryMinimumGasPricesRequest proto.InternalMessageInfo

// QueryMinimumGasPricesResponse is the response type for the
// Query/MinimumGasPrices RPC method.
type QueryMinimumGasPricesResponse struct {
	MinimumGasPrices github_com_cosmos_cosmos_sdk_types.DecCoins `protobuf:"bytes,1,rep,name=minimum_gas_prices,json=minimumGasPrices,proto3,castrepeated=github.com/cosmos/cosmos-sdk/types.DecCoins" json:"minimum_gas_prices,omitempty" yaml:"minimum_gas_prices"`
}

func (m *QueryMinimumGasPricesResponse) Reset()         { *m = QueryMinimumGasPricesResponse{} }
func (m *QueryMinimumGasPricesResponse) String() string { return proto.CompactTextString(m) }
func (*QueryMinimumGasPricesResponse) ProtoMessage()    {}
func (*QueryMinimumGasPricesResponse) Descriptor() ([]byte, []int) {
	return fileDescriptor_12a736cede25d10a, []int{1}
}
func (m *QueryMinimumGasPricesResponse) XXX_Unmarshal(b []byte) error {
	return m.Unmarshal(b)
}
func (m *QueryMinimumGasPricesResponse) XXX_Marshal(b []byte, deterministic bool) ([]byte, error) {
	if deterministic {
		return xxx_messageInfo_QueryMinimumGasPricesResponse.Marshal(b, m, deterministic)
	} else {
		b = b[:cap(b)]
		n, err := m.MarshalToSizedBuffer(b)
		if err != nil {
			return nil, err
		}
		return b[:n], nil
	}
}
func (m *QueryMinimumGasPricesResponse) XXX_Merge(src proto.Message) {
	xxx_messageInfo_QueryMinimumGasPricesResponse.Merge(m, src)
}
func (m *QueryMinimumGasPricesResponse) XXX_Size() int {
	return m.Size()
}
func (m *QueryMinimumGasPricesResponse) XXX_DiscardUnknown() {
	xxx_messageInfo_QueryMinimumGasPricesResponse.DiscardUnknown(m)
}

var xxx_messageInfo_QueryMinimumGasPricesResponse proto.InternalMessageInfo

func (m *QueryMinimumGasPricesResponse) GetMinimumGasPrices() github_com_cosmos_cosmos_sdk_types.DecCoins {
	if m != nil {
		return m.MinimumGasPrices
	}
	return nil
}

func init() {
	proto.RegisterType((*QueryMinimumGasPricesRequest)(nil), "gaia.globalfee.v1beta1.QueryMinimumGasPricesRequest")
	proto.RegisterType((*QueryMinimumGasPricesResponse)(nil), "gaia.globalfee.v1beta1.QueryMinimumGasPricesResponse")
}

func init() {
	proto.RegisterFile("gaia/globalfee/v1beta1/query.proto", fileDescriptor_12a736cede25d10a)
}

var fileDescriptor_12a736cede25d10a = []byte{
	// 377 bytes of a gzipped FileDescriptorProto
	0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff, 0x94, 0x92, 0xb1, 0x4f, 0xdb, 0x40,
	0x14, 0xc6, 0x7d, 0xad, 0xda, 0xc1, 0x5d, 0x22, 0xab, 0xaa, 0xda, 0xc8, 0x3d, 0x57, 0x9e, 0xa2,
	0x36, 0xbd, 0x53, 0xd2, 0x76, 0xe9, 0x98, 0x56, 0x62, 0x42, 0x82, 0x8c, 0x2c, 0xd1, 0xd9, 0x1c,
	0xc7, 0x09, 0x9f, 0x9f, 0x93, 0x3b, 0x23, 0xbc, 0xf2, 0x17, 0x20, 0xf1, 0x5f, 0xb0, 0xb2, 0xc2,
	0x9e, 0x31, 0x12, 0x0b, 0x93, 0x41, 0x09, 0x13, 0x23, 0x7f, 0x01, 0xb2, 0x9d, 0x00, 0x8a, 0x09,
	0x12, 0x93, 0x2d, 0x7d, 0xbf, 0xf7, 0x3e, 0x7d, 0xdf, 0x3d, 0xdb, 0x17, 0x4c, 0x32, 0x2a, 0x22,
	0x08, 0x58, 0xb4, 0xc3, 0x39, 0xdd, 0xef, 0x04, 0xdc, 0xb0, 0x0e, 0x1d, 0xa6, 0x7c, 0x94, 0x91,
	0x64, 0x04, 0x06, 0x9c, 0x4f, 0x05, 0x43, 0x1e, 0x18, 0x32, 0x67, 0x9a, 0x1f, 0x05, 0x08, 0x28,
	0x11, 0x5a, 0xfc, 0x55, 0x74, 0xd3, 0x15, 0x00, 0x22, 0xe2, 0x94, 0x25, 0x92, 0xb2, 0x38, 0x06,
	0xc3, 0x8c, 0x84, 0x58, 0xcf, 0x55, 0x1c, 0x82, 0x56, 0xa0, 0x69, 0xc0, 0xf4, 0xa3, 0x59, 0x08,
	0x32, 0xae, 0x74, 0x1f, 0xdb, 0xee, 0x66, 0x61, 0xbd, 0x2e, 0x63, 0xa9, 0x52, 0xb5, 0xc6, 0xf4,
	0xc6, 0x48, 0x86, 0x5c, 0xf7, 0xf9, 0x30, 0xe5, 0xda, 0xf8, 0x39, 0xb2, 0xbf, 0xae, 0x00, 0x74,
	0x02, 0xb1, 0xe6, 0xce, 0x19, 0xb2, 0x1d, 0x55, 0x89, 0x03, 0xc1, 0xf4, 0x20, 0x29, 0xe5, 0xcf,
	0xe8, 0xdb, 0xdb, 0xd6, 0x87, 0xae, 0x4b, 0x2a, 0x7f, 0x52, 0xf8, 0x2f, 0x82, 0x90, 0xff, 0x3c,
	0xfc, 0x07, 0x32, 0xee, 0x25, 0xe3, 0xdc, 0xb3, 0x6e, 0x73, 0xcf, 0xad, 0xcf, 0xb7, 0x41, 0x49,
	0xc3, 0x55, 0x62, 0xb2, 0xbb, 0xdc, 0xfb, 0x92, 0x31, 0x15, 0xfd, 0xf5, 0xeb, 0x94, 0x7f, 0x72,
	0xe5, 0xfd, 0x10, 0xd2, 0xec, 0xa6, 0x01, 0x09, 0x41, 0xd1, 0x79, 0xd8, 0xea, 0xf3, 0x53, 0x6f,
	0xef, 0x51, 0x93, 0x25, 0x5c, 0x2f, 0x0c, 0x75, 0xbf, 0xa1, 0x96, 0x62, 0x74, 0xcf, 0x91, 0xfd,
	0xae, 0x0c, 0xe8, 0x9c, 0x22, 0xbb, 0xb1, 0x9c, 0xd2, 0xf9, 0x4d, 0x9e, 0x7f, 0x0c, 0xf2, 0x52,
	0x6b, 0xcd, 0x3f, 0xaf, 0x9c, 0xaa, 0xaa, 0xf4, 0xbb, 0x87, 0x17, 0x37, 0xc7, 0x6f, 0xda, 0xce,
	0x77, 0xba, 0xe2, 0x4a, 0xea, 0x0d, 0xf4, 0x7a, 0xe3, 0x29, 0x46, 0x93, 0x29, 0x46, 0xd7, 0x53,
	0x8c, 0x8e, 0x66, 0xd8, 0x9a, 0xcc, 0xb0, 0x75, 0x39, 0xc3, 0xd6, 0x56, 0xab, 0x5e, 0x4c, 0xb9,
	0xf6, 0xe0, 0xc9, 0xe2, 0xb2, 0x9e, 0xe0, 0x7d, 0x79, 0x0b, 0xbf, 0xee, 0x03, 0x00, 0x00, 0xff,
	0xff, 0x73, 0x0d, 0xf8, 0x43, 0x9d, 0x02, 0x00, 0x00,
}

// Reference imports to suppress errors if they are not otherwise used.
var _ context.Context
var _ grpc.ClientConn

// This is a compile-time assertion to ensure that this generated file
// is compatible with the grpc package it is being compiled against.
const _ = grpc.SupportPackageIsVersion4

// QueryClient is the client API for Query service.
//
// For semantics around ctx use and closing/ending streaming RPCs, please refer to https://godoc.org/google.golang.org/grpc#ClientConn.NewStream.
type QueryClient interface {
	// MinimumGasPrices returns the minimum gas prices.
	MinimumGasPrices(ctx context.Context, in *QueryMinimumGasPricesRequest, opts ...grpc.CallOption) (*QueryMinimumGasPricesResponse, error)
}

type queryClient struct {
	cc grpc1.ClientConn
}

func NewQueryClient(cc grpc1.ClientConn) QueryClient {
	return &queryClient{cc}
}

func (c *queryClient) MinimumGasPrices(ctx context.Context, in *QueryMinimumGasPricesRequest, opts ...grpc.CallOption) (*QueryMinimumGasPricesResponse, error) {
	out := new(QueryMinimumGasPricesResponse)
	err := c.cc.Invoke(ctx, "/gaia.globalfee.v1beta1.Query/MinimumGasPrices", in, out, opts...)
	if err != nil {
		return nil, err
	}
	return out, nil
}

// QueryServer is the server API for Query service.
type QueryServer interface {
	// MinimumGasPrices returns the minimum gas prices.
	MinimumGasPrices(context.Context, *QueryMinimumGasPricesRequest) (*QueryMinimumGasPricesResponse, error)
}

// UnimplementedQueryServer can be embedded to have forward compatible implementations.
type UnimplementedQueryServer struct {
}

func (*UnimplementedQueryServer) MinimumGasPrices(ctx context.Context, req *QueryMinimumGasPricesRequest) (*QueryMinimumGasPricesResponse, error) {
	return nil, status.Errorf(codes.Unimplemented, "method MinimumGasPrices not implemented")
}

func RegisterQueryServer(s grpc1.Server, srv QueryServer) {
	s.RegisterService(&_Query_serviceDesc, srv)
}

func _Query_MinimumGasPrices_Handler(srv interface{}, ctx context.Context, dec func(interface{}) error, interceptor grpc.UnaryServerInterceptor) (interface{}, error) {
	in := new(QueryMinimumGasPricesRequest)
	if err := dec(in); err != nil {
		return nil, err
	}
	if interceptor == nil {
		return srv.(QueryServer).MinimumGasPrices(ctx, in)
	}
	info := &grpc.UnaryServerInfo{
		Server:     srv,
		FullMethod: "/gaia.globalfee.v1beta1.Query/MinimumGasPrices",
	}
	handler := func(ctx context.Context, req interface{}) (interface{}, error) {
		return srv.(QueryServer).MinimumGasPrices(ctx, req.(*QueryMinimumGasPricesRequest))
	}
	return interceptor(ctx, in, info, handler)
}

var _Query_serviceDesc = grpc.ServiceDesc{
	ServiceName: "gaia.globalfee.v1beta1.Query",
	HandlerType: (*QueryServer)(nil),
	Methods: []grpc.MethodDesc{
		{
			MethodName: "MinimumGasPrices",
			Handler:    _Query_MinimumGasPrices_Handler,
		},
	},
	Streams:  []grpc.StreamDesc{},
	Metadata: "gaia/globalfee/v1beta1/query.proto",
}

func (m *QueryMinimumGasPricesRequest) Marshal() (dAtA []byte, err error) {
	size := m.Size()
	dAtA = make([]byte, size)
	n, err := m.MarshalToSizedBuffer(dAtA[:size])
	if err != nil {
		return nil, err
	}
	return dAtA[:n], nil
}

func (m *QueryMinimumGasPricesRequest) MarshalTo(dAtA []byte) (int, error) {
	size := m.Size()
	return m.MarshalToSizedBuffer(dAtA[:size])
}

func (m *QueryMinimumGasPricesRequest) MarshalToSizedBuffer(dAtA []byte) (int, error) {
	i := len(dAtA)
	_ = i
	var l int
	_ = l
	return len(dAtA) - i, nil
}

func (m *QueryMinimumGasPricesResponse) Marshal() (dAtA []byte, err error) {
	size := m.Size()
	dAtA = make([]byte, size)
	n, err := m.MarshalToSizedBuffer(dAtA[:size])
	if err != nil {
		return nil, err
	}
	return dAtA[:n], nil
}

func (m *QueryMinimumGasPricesResponse) MarshalTo(dAtA []byte) (int, error) {
	size := m.Size()
	return m.MarshalToSizedBuffer(dAtA[:size])
}

func (m *QueryMinimumGasPricesResponse) MarshalToSizedBuffer(dAtA []byte) (int, error) {
	i := len(dAtA)
	_ = i
	var l int
	_ = l
	if len(m.MinimumGasPrices) > 0 {
		for iNdEx := len(m.MinimumGasPrices) - 1; iNdEx >= 0; iNdEx-- {
			{
				size, err := m.MinimumGasPrices[iNdEx].MarshalToSizedBuffer(dAtA[:i])
				if err != nil {
					return 0, err
				}
				i -= size
				i = encodeVarintQuery(dAtA, i, uint64(size))
			}
			i--
			dAtA[i] = 0xa
		}
	}
	return len(dAtA) - i, nil
}

func encodeVarintQuery(dAtA []byte, offset int, v uint64) int {
	offset -= sovQuery(v)
	base := offset
	for v >= 1<<7 {
		dAtA[offset] = uint8(v&0x7f | 0x80)
		v >>= 7
		offset++
	}
	dAtA[offset] = uint8(v)
	return base
}
func (m *QueryMinimumGasPricesRequest) Size() (n int) {
	if m == nil {
		return 0
	}
	var l int
	_ = l
	return n
}

func (m *QueryMinimumGasPricesResponse) Size() (n int) {
	if m == nil {
		return 0
	}
	var l int
	_ = l
	if len(m.MinimumGasPrices) > 0 {
		for _, e := range m.MinimumGasPrices {
			l = e.Size()
			n += 1 + l + sovQuery(uint64(l))
		}
	}
	return n
}

func sovQuery(x uint64) (n int) {
	return (math_bits.Len64(x|1) + 6) / 7
}
func sozQuery(x uint64) (n int) {
	return sovQuery(uint64((x << 1) ^ uint64((int64(x) >> 63))))
}
func (m *QueryMinimumGasPricesRequest) Unmarshal(dAtA []byte) error {
	l := len(dAtA)
	iNdEx := 0
	for iNdEx < l {
		preIndex := iNdEx
		var wire uint64
		for shift := uint(0); ; shift += 7 {
			if shift >= 64 {
				return ErrIntOverflowQuery
			}
			if iNdEx >= l {
				return io.ErrUnexpectedEOF
			}
			b := dAtA[iNdEx]
			iNdEx++
			wire |= uint64(b&0x7F) << shift
			if b < 0x80 {
				break
			}
		}
		fieldNum := int32(wire >> 3)
		wireType := int(wire & 0x7)
		if wireType == 4 {
			return fmt.Errorf("proto: QueryMinimumGasPricesRequest: wiretype end group for non-group")
		}
		if fieldNum <= 0 {
			return fmt.Errorf("proto: QueryMinimumGasPricesRequest: illegal tag %d (wire type %d)", fieldNum, wire)
		}
		switch fieldNum {
		default:
			iNdEx = preIndex
			skippy, err := skipQuery(dAtA[iNdEx:])
			if err != nil {
				return err
			}
			if (skippy < 0) || (iNdEx+skippy) < 0 {
				return ErrInvalidLengthQuery
			}
			if (iNdEx + skippy) > l {
				return io.ErrUnexpectedEOF
			}
			iNdEx += skippy
		}
	}

	if iNdEx > l {
		return io.ErrUnexpectedEOF
	}
	return nil
}
func (m *QueryMinimumGasPricesResponse) Unmarshal(dAtA []byte) error {
	l := len(dAtA)
	iNdEx := 0
	for iNdEx < l {
		preIndex := iNdEx
		var wire uint64
		for shift := uint(0); ; shift += 7 {
			if shift >= 64 {
				return ErrIntOverflowQuery
			}
			if iNdEx >= l {
				return io.ErrUnexpectedEOF
			}
			b := dAtA[iNdEx]
			iNdEx++
			wire |= uint64(b&0x7F) << shift
			if b < 0x80 {
				break
			}
		}
		fieldNum := int32(wire >> 3)
		wireType := int(wire & 0x7)
		if wireType == 4 {
			return fmt.Errorf("proto: QueryMinimumGasPricesResponse: wiretype end group for non-group")
		}
		if fieldNum <= 0 {
			return fmt.Errorf("proto: QueryMinimumGasPricesResponse: illegal tag %d (wire type %d)", fieldNum, wire)
		}
		switch fieldNum {
		case 1:
			if wireType != 2 {
				return fmt.Errorf("proto: wrong wireType = %d for field MinimumGasPrices", wireType)
			}
			var msglen int
			for shift := uint(0); ; shift += 7 {
				if shift >= 64 {
					return ErrIntOverflowQuery
				}
				if iNdEx >= l {
					return io.ErrUnexpectedEOF
				}
				b := dAtA[iNdEx]
				iNdEx++
				msglen |= int(b&0x7F) << shift
				if b < 0x80 {
					break
				}
			}
			if msglen < 0 {
				return ErrInvalidLengthQuery
			}
			postIndex := iNdEx + msglen
			if postIndex < 0 {
				return ErrInvalidLengthQuery
			}
			if postIndex > l {
				return io.ErrUnexpectedEOF
			}
			m.MinimumGasPrices = append(m.MinimumGasPrices, types.DecCoin{})
			if err := m.MinimumGasPrices[len(m.MinimumGasPrices)-1].Unmarshal(dAtA[iNdEx:postIndex]); err != nil {
				return err
			}
			iNdEx = postIndex
		default:
			iNdEx = preIndex
			skippy, err := skipQuery(dAtA[iNdEx:])
			if err != nil {
				return err
			}
			if (skippy < 0) || (iNdEx+skippy) < 0 {
				return ErrInvalidLengthQuery
			}
			if (iNdEx + skippy) > l {
				return io.ErrUnexpectedEOF
			}
			iNdEx += skippy
		}
	}

	if iNdEx > l {
		return io.ErrUnexpectedEOF
	}
	return nil
}
func skipQuery(dAtA []byte) (n int, err error) {
	l := len(dAtA)
	iNdEx := 0
	depth := 0
	for iNdEx < l {
		var wire uint64
		for shift := uint(0); ; shift += 7 {
			if shift >= 64 {
				return 0, ErrIntOverflowQuery
			}
			if iNdEx >= l {
				return 0, io.ErrUnexpectedEOF
			}
			b := dAtA[iNdEx]
			iNdEx++
			wire |= (uint64(b) & 0x7F) << shift
			if b < 0x80 {
				break
			}
		}
		wireType := int(wire & 0x7)
		switch wireType {
		case 0:
			for shift := uint(0); ; shift += 7 {
				if shift >= 64 {
					return 0, ErrIntOverflowQuery
				}
				if iNdEx >= l {
					return 0, io.ErrUnexpectedEOF
				}
				iNdEx++
				if dAtA[iNdEx-1] < 0x80 {
					break
				}
			}
		case 1:
			iNdEx += 8
		case 2:
			var length int
			for shift := uint(0); ; shift += 7 {
				if shift >= 64 {
					return 0, ErrIntOverflowQuery
				}
				if iNdEx >= l {
					return 0, io.ErrUnexpectedEOF
				}
				b := dAtA[iNdEx]
				iNdEx++
				length |= (int(b) & 0x7F) << shift
				if b < 0x80 {
					break
				}
			}
			if length < 0 {
				return 0, ErrInvalidLengthQuery
			}
			iNdEx += length
		case 3:
			depth++
		case 4:
			if depth == 0 {
				return 0, ErrUnexpectedEndOfGroupQuery
			}
			depth--
		case 5:
			iNdEx += 4
		default:
			return 0, fmt.Errorf("proto: illegal wireType %d", wireType)
		}
		if iNdEx < 0 {
			return 0, ErrInvalidLengthQuery
		}
		if depth == 0 {
			return iNdEx, nil
		}
	}
	return 0, io.ErrUnexpectedEOF
}

var (
	ErrInvalidLengthQuery        = fmt.Errorf("proto: negative length found during unmarshaling")
	ErrIntOverflowQuery          = fmt.Errorf("proto: integer overflow")
	ErrUnexpectedEndOfGroupQuery = fmt.Errorf("proto: unexpected end of group")
)
