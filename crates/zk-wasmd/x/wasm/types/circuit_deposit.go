package types

import (
	fmt "fmt"
	io "io"
	math_bits "math/bits"

	sdk "github.com/cosmos/cosmos-sdk/types"
	sdkerrors "github.com/cosmos/cosmos-sdk/types/errors"
	proto "github.com/cosmos/gogoproto/proto"
)

const (
	CircuitDepositSecondsPerYear = int64(365 * 24 * 3600)
	CircuitDepositMaxYears       = uint32(10)
	CircuitDepositYearlyAmount   = int64(1_000_000)
	// Bounded EndBlocker GC: expired depositees then their circuit blobs.
	MaxCircuitDepositGCDepositees = 8
	MaxCircuitDepositGCCircuits   = 2
	// Circuit runway payment split (not stake-weighted).
	CircuitValPoolName = "circuit_val_pool"
	CircuitDevPoolName = "circuit_dev_pool"
	// CircuitDistrEpochDay is the Osmosis-style identifier wasm filters on AfterEpochEnd.
	CircuitDistrEpochDay = "day"
	// CircuitEpochDurationDefault is 24h until x/epochs is mounted.
	CircuitEpochDurationDefault = int64(24 * 3600)
)

var (
	_ sdk.Msg       = (*MsgPayCircuitDeposit)(nil)
	_ proto.Message = (*MsgPayCircuitDeposit)(nil)
)

func init() {
	proto.RegisterType((*MsgPayCircuitDeposit)(nil), "cosmwasm.wasm.v1.MsgPayCircuitDeposit")
	proto.RegisterType((*MsgPayCircuitDepositResponse)(nil), "cosmwasm.wasm.v1.MsgPayCircuitDepositResponse")
	proto.RegisterType((*QueryCircuitDepositRequest)(nil), "cosmwasm.wasm.v1.QueryCircuitDepositRequest")
	proto.RegisterType((*QueryCircuitDepositResponse)(nil), "cosmwasm.wasm.v1.QueryCircuitDepositResponse")
}

// MsgPayCircuitDeposit pays yearly circuit-upload coverage for the sender.
// Allowlisted CircuitUploadAccess actors do not need this.
type MsgPayCircuitDeposit struct {
	Sender string `protobuf:"bytes,1,opt,name=sender,proto3" json:"sender,omitempty"`
	Years  uint32 `protobuf:"varint,2,opt,name=years,proto3" json:"years,omitempty"`
}

func (m *MsgPayCircuitDeposit) Reset()         { *m = MsgPayCircuitDeposit{} }
func (m *MsgPayCircuitDeposit) String() string { return proto.CompactTextString(m) }
func (*MsgPayCircuitDeposit) ProtoMessage()    {}
func (*MsgPayCircuitDeposit) Descriptor() ([]byte, []int) {
	return fileDescriptor_4f74d82755520264, []int{48}
}
func (m *MsgPayCircuitDeposit) ValidateBasic() error {
	if _, err := sdk.AccAddressFromBech32(m.Sender); err != nil {
		return sdkerrors.ErrInvalidAddress.Wrap("sender")
	}
	if m.Years == 0 || m.Years > CircuitDepositMaxYears {
		return ErrLimit.Wrapf("years must be 1..%d", CircuitDepositMaxYears)
	}
	return nil
}
func (m *MsgPayCircuitDeposit) GetSigners() []sdk.AccAddress {
	a, _ := sdk.AccAddressFromBech32(m.Sender)
	return []sdk.AccAddress{a}
}

type MsgPayCircuitDepositResponse struct {
	PaidUntilUnix int64 `json:"paid_until_unix"`
}

func (m *MsgPayCircuitDepositResponse) Reset()         { *m = MsgPayCircuitDepositResponse{} }
func (m *MsgPayCircuitDepositResponse) String() string { return proto.CompactTextString(m) }
func (*MsgPayCircuitDepositResponse) ProtoMessage()    {}
func (*MsgPayCircuitDepositResponse) Descriptor() ([]byte, []int) {
	return fileDescriptor_4f74d82755520264, []int{49}
}

// SplitCircuitRunway is a 50/50 split. Odd leftover uterp goes to the dev/maintenance pool.
func SplitCircuitRunway(amt sdk.Coins) (valPool, devPool sdk.Coins) {
	for _, c := range amt {
		if !c.IsPositive() {
			continue
		}
		half := c.Amount.QuoRaw(2)
		rest := c.Amount.Sub(half)
		if half.IsPositive() {
			valPool = valPool.Add(sdk.NewCoin(c.Denom, half))
		}
		if rest.IsPositive() {
			devPool = devPool.Add(sdk.NewCoin(c.Denom, rest))
		}
	}
	return valPool, devPool
}

func CircuitDepositQuote(denom string, years uint32) (sdk.Coins, error) {
	if years == 0 || years > CircuitDepositMaxYears {
		return nil, ErrLimit.Wrapf("years must be 1..%d", CircuitDepositMaxYears)
	}
	if denom == "" {
		return nil, fmt.Errorf("deposit denom empty")
	}
	return sdk.NewCoins(sdk.NewInt64Coin(denom, CircuitDepositYearlyAmount*int64(years))), nil
}

func encodeVarintDeposit(dAtA []byte, offset int, v uint64) int {
	offset -= sovDeposit(v)
	base := offset
	for v >= 1<<7 {
		dAtA[offset] = uint8(v&0x7f | 0x80)
		v >>= 7
		offset++
	}
	dAtA[offset] = uint8(v)
	return base
}

func sovDeposit(x uint64) int { return (math_bits.Len64(x|1) + 6) / 7 }

func (m *MsgPayCircuitDeposit) Marshal() ([]byte, error) {
	size := m.Size()
	dAtA := make([]byte, size)
	n, err := m.MarshalToSizedBuffer(dAtA[:size])
	if err != nil {
		return nil, err
	}
	return dAtA[:n], nil
}
func (m *MsgPayCircuitDeposit) Size() (n int) {
	if m == nil {
		return 0
	}
	if l := len(m.Sender); l > 0 {
		n += 1 + l + sovDeposit(uint64(l))
	}
	if m.Years != 0 {
		n += 1 + sovDeposit(uint64(m.Years))
	}
	return n
}
func (m *MsgPayCircuitDeposit) MarshalToSizedBuffer(dAtA []byte) (int, error) {
	i := len(dAtA)
	if m.Years != 0 {
		i = encodeVarintDeposit(dAtA, i, uint64(m.Years))
		i--
		dAtA[i] = 0x10
	}
	if len(m.Sender) > 0 {
		i -= len(m.Sender)
		copy(dAtA[i:], m.Sender)
		i = encodeVarintDeposit(dAtA, i, uint64(len(m.Sender)))
		i--
		dAtA[i] = 0xa
	}
	return len(dAtA) - i, nil
}
func (m *MsgPayCircuitDeposit) XXX_Size() int { return m.Size() }
func (m *MsgPayCircuitDeposit) XXX_Marshal(_ []byte, _ bool) ([]byte, error) {
	return m.Marshal()
}
func (m *MsgPayCircuitDeposit) XXX_Unmarshal(b []byte) error { return m.Unmarshal(b) }
func (m *MsgPayCircuitDeposit) XXX_Merge(_ interface{})      {}
func (m *MsgPayCircuitDeposit) XXX_DiscardUnknown()          {}

func (m *MsgPayCircuitDeposit) Unmarshal(dAtA []byte) error {
	l := len(dAtA)
	iNdEx := 0
	for iNdEx < l {
		var wire uint64
		for shift := uint(0); ; shift += 7 {
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
		switch fieldNum {
		case 1:
			var sl int
			for shift := uint(0); ; shift += 7 {
				if iNdEx >= l {
					return io.ErrUnexpectedEOF
				}
				b := dAtA[iNdEx]
				iNdEx++
				sl |= int(b&0x7F) << shift
				if b < 0x80 {
					break
				}
			}
			m.Sender = string(dAtA[iNdEx : iNdEx+sl])
			iNdEx += sl
		case 2:
			for shift := uint(0); ; shift += 7 {
				if iNdEx >= l {
					return io.ErrUnexpectedEOF
				}
				b := dAtA[iNdEx]
				iNdEx++
				m.Years |= uint32(b&0x7F) << shift
				if b < 0x80 {
					break
				}
			}
		default:
			return io.ErrUnexpectedEOF
		}
	}
	return nil
}

func (m *MsgPayCircuitDepositResponse) Marshal() ([]byte, error) {
	dAtA := make([]byte, 11)
	i := len(dAtA)
	if m.PaidUntilUnix != 0 {
		i = encodeVarintDeposit(dAtA, i, uint64(m.PaidUntilUnix))
		i--
		dAtA[i] = 0x8
	}
	return dAtA[i:], nil
}
func (m *MsgPayCircuitDepositResponse) XXX_Size() int { return 0 }
func (m *MsgPayCircuitDepositResponse) XXX_Marshal(_ []byte, _ bool) ([]byte, error) {
	return m.Marshal()
}
func (m *MsgPayCircuitDepositResponse) XXX_Unmarshal([]byte) error { return nil }
func (m *MsgPayCircuitDepositResponse) XXX_Merge(_ interface{})    {}
func (m *MsgPayCircuitDepositResponse) XXX_DiscardUnknown()        {}

type QueryCircuitDepositRequest struct {
	Address string `protobuf:"bytes,1,opt,name=address,proto3" json:"address,omitempty"`
}

func (m *QueryCircuitDepositRequest) Reset()         { *m = QueryCircuitDepositRequest{} }
func (m *QueryCircuitDepositRequest) String() string { return proto.CompactTextString(m) }
func (*QueryCircuitDepositRequest) ProtoMessage()    {}
func (m *QueryCircuitDepositRequest) Marshal() ([]byte, error) {
	size := 0
	if l := len(m.Address); l > 0 {
		size = 1 + l + sovDeposit(uint64(l))
	}
	dAtA := make([]byte, size)
	i := len(dAtA)
	if len(m.Address) > 0 {
		i -= len(m.Address)
		copy(dAtA[i:], m.Address)
		i = encodeVarintDeposit(dAtA, i, uint64(len(m.Address)))
		i--
		dAtA[i] = 0xa
	}
	return dAtA[i:], nil
}
func (m *QueryCircuitDepositRequest) Unmarshal(dAtA []byte) error {
	l := len(dAtA)
	iNdEx := 0
	for iNdEx < l {
		var wire uint64
		for shift := uint(0); ; shift += 7 {
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
		if int32(wire>>3) != 1 {
			return io.ErrUnexpectedEOF
		}
		var sl int
		for shift := uint(0); ; shift += 7 {
			if iNdEx >= l {
				return io.ErrUnexpectedEOF
			}
			b := dAtA[iNdEx]
			iNdEx++
			sl |= int(b&0x7F) << shift
			if b < 0x80 {
				break
			}
		}
		m.Address = string(dAtA[iNdEx : iNdEx+sl])
		iNdEx += sl
	}
	return nil
}
func (m *QueryCircuitDepositRequest) XXX_Size() int { return 0 }
func (m *QueryCircuitDepositRequest) XXX_Marshal(_ []byte, _ bool) ([]byte, error) {
	return m.Marshal()
}
func (m *QueryCircuitDepositRequest) XXX_Unmarshal(b []byte) error { return m.Unmarshal(b) }
func (m *QueryCircuitDepositRequest) XXX_Merge(_ interface{})      {}
func (m *QueryCircuitDepositRequest) XXX_DiscardUnknown()          {}

type QueryCircuitDepositResponse struct {
	Address       string `protobuf:"bytes,1,opt,name=address,proto3" json:"address,omitempty"`
	PaidUntilUnix int64  `protobuf:"varint,2,opt,name=paid_until_unix,json=paidUntilUnix,proto3" json:"paid_until_unix"`
	Covered       bool   `protobuf:"varint,3,opt,name=covered,proto3" json:"covered"`
}

func (m *QueryCircuitDepositResponse) Reset()         { *m = QueryCircuitDepositResponse{} }
func (m *QueryCircuitDepositResponse) String() string { return proto.CompactTextString(m) }
func (*QueryCircuitDepositResponse) ProtoMessage()    {}
func (m *QueryCircuitDepositResponse) Marshal() ([]byte, error) {
	l := 0
	if n := len(m.Address); n > 0 {
		l += 1 + n + sovDeposit(uint64(n))
	}
	if m.PaidUntilUnix != 0 {
		l += 1 + sovDeposit(uint64(m.PaidUntilUnix))
	}
	if m.Covered {
		l += 2
	}
	dAtA := make([]byte, l)
	i := len(dAtA)
	if m.Covered {
		i--
		if m.Covered {
			dAtA[i] = 1
		} else {
			dAtA[i] = 0
		}
		i--
		dAtA[i] = 0x18
	}
	if m.PaidUntilUnix != 0 {
		i = encodeVarintDeposit(dAtA, i, uint64(m.PaidUntilUnix))
		i--
		dAtA[i] = 0x10
	}
	if len(m.Address) > 0 {
		i -= len(m.Address)
		copy(dAtA[i:], m.Address)
		i = encodeVarintDeposit(dAtA, i, uint64(len(m.Address)))
		i--
		dAtA[i] = 0xa
	}
	return dAtA[i:], nil
}
func (m *QueryCircuitDepositResponse) Unmarshal(dAtA []byte) error {
	l := len(dAtA)
	iNdEx := 0
	for iNdEx < l {
		var wire uint64
		for shift := uint(0); ; shift += 7 {
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
		switch int32(wire >> 3) {
		case 1:
			var sl int
			for shift := uint(0); ; shift += 7 {
				if iNdEx >= l {
					return io.ErrUnexpectedEOF
				}
				b := dAtA[iNdEx]
				iNdEx++
				sl |= int(b&0x7F) << shift
				if b < 0x80 {
					break
				}
			}
			m.Address = string(dAtA[iNdEx : iNdEx+sl])
			iNdEx += sl
		case 2:
			for shift := uint(0); ; shift += 7 {
				if iNdEx >= l {
					return io.ErrUnexpectedEOF
				}
				b := dAtA[iNdEx]
				iNdEx++
				m.PaidUntilUnix |= int64(b&0x7F) << shift
				if b < 0x80 {
					break
				}
			}
		case 3:
			v := uint64(0)
			for shift := uint(0); ; shift += 7 {
				if iNdEx >= l {
					return io.ErrUnexpectedEOF
				}
				b := dAtA[iNdEx]
				iNdEx++
				v |= uint64(b&0x7F) << shift
				if b < 0x80 {
					break
				}
			}
			m.Covered = v != 0
		default:
			return io.ErrUnexpectedEOF
		}
	}
	return nil
}
func (m *QueryCircuitDepositResponse) XXX_Size() int { return 0 }
func (m *QueryCircuitDepositResponse) XXX_Marshal(_ []byte, _ bool) ([]byte, error) {
	return m.Marshal()
}
func (m *QueryCircuitDepositResponse) XXX_Unmarshal(b []byte) error { return m.Unmarshal(b) }
func (m *QueryCircuitDepositResponse) XXX_Merge(_ interface{})      {}
func (m *QueryCircuitDepositResponse) XXX_DiscardUnknown()          {}
