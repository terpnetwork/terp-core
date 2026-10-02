package types

import (
	fmt "fmt"
	io "io"
	math_bits "math/bits"
)

// VkParam is a standalone commitment-parameter set for genesis / state sync.
// Matches cosmwasm/wasm/v1/genesis.proto message VkParam.
// Raw ParamBytes are for StoreParam / cold path only — never public query data.
type VkParam struct {
	ParamID    uint64 `protobuf:"varint,1,opt,name=param_id,json=paramId,proto3" json:"param_id,omitempty"`
	ParamKey   []byte `protobuf:"bytes,2,opt,name=param_key,json=paramKey,proto3" json:"param_key,omitempty"`
	Creator    string `protobuf:"bytes,3,opt,name=creator,proto3" json:"creator,omitempty"`
	ParamBytes []byte `protobuf:"bytes,4,opt,name=param_bytes,json=paramBytes,proto3" json:"param_bytes,omitempty"`
}

func (m *VkParam) Reset()         { *m = VkParam{} }
func (m *VkParam) String() string { return fmt.Sprintf("%+v", *m) }
func (*VkParam) ProtoMessage()    {}

func (m *VkParam) Marshal() (dAtA []byte, err error) {
	size := m.Size()
	dAtA = make([]byte, size)
	n, err := m.MarshalToSizedBuffer(dAtA[:size])
	if err != nil {
		return nil, err
	}
	return dAtA[:n], nil
}

func (m *VkParam) MarshalTo(dAtA []byte) (int, error) {
	size := m.Size()
	return m.MarshalToSizedBuffer(dAtA[:size])
}

func (m *VkParam) MarshalToSizedBuffer(dAtA []byte) (int, error) {
	i := len(dAtA)
	if m.ParamBytes != nil {
		i -= len(m.ParamBytes)
		copy(dAtA[i:], m.ParamBytes)
		i = encodeVarintGenesis(dAtA, i, uint64(len(m.ParamBytes)))
		i--
		dAtA[i] = 0x22
	}
	if len(m.Creator) > 0 {
		i -= len(m.Creator)
		copy(dAtA[i:], m.Creator)
		i = encodeVarintGenesis(dAtA, i, uint64(len(m.Creator)))
		i--
		dAtA[i] = 0x1a
	}
	if m.ParamKey != nil {
		i -= len(m.ParamKey)
		copy(dAtA[i:], m.ParamKey)
		i = encodeVarintGenesis(dAtA, i, uint64(len(m.ParamKey)))
		i--
		dAtA[i] = 0x12
	}
	if m.ParamID != 0 {
		i = encodeVarintGenesis(dAtA, i, uint64(m.ParamID))
		i--
		dAtA[i] = 0x8
	}
	return len(dAtA) - i, nil
}

func (m *VkParam) Size() (n int) {
	if m == nil {
		return 0
	}
	if m.ParamID != 0 {
		n += 1 + sovGenesis(uint64(m.ParamID))
	}
	l := len(m.ParamKey)
	if l > 0 {
		n += 1 + l + sovGenesis(uint64(l))
	}
	l = len(m.Creator)
	if l > 0 {
		n += 1 + l + sovGenesis(uint64(l))
	}
	l = len(m.ParamBytes)
	if l > 0 {
		n += 1 + l + sovGenesis(uint64(l))
	}
	return n
}

func (m *VkParam) Unmarshal(dAtA []byte) error {
	l := len(dAtA)
	iNdEx := 0
	for iNdEx < l {
		preIndex := iNdEx
		var wire uint64
		for shift := uint(0); ; shift += 7 {
			if shift >= 64 {
				return ErrIntOverflowGenesis
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
			return fmt.Errorf("proto: VkParam: wiretype end group for non-group")
		}
		if fieldNum <= 0 {
			return fmt.Errorf("proto: VkParam: illegal tag %d (wire type %d)", fieldNum, wire)
		}
		switch fieldNum {
		case 1:
			if wireType != 0 {
				return fmt.Errorf("proto: wrong wireType = %d for field ParamID", wireType)
			}
			m.ParamID = 0
			for shift := uint(0); ; shift += 7 {
				if shift >= 64 {
					return ErrIntOverflowGenesis
				}
				if iNdEx >= l {
					return io.ErrUnexpectedEOF
				}
				b := dAtA[iNdEx]
				iNdEx++
				m.ParamID |= uint64(b&0x7F) << shift
				if b < 0x80 {
					break
				}
			}
		case 2:
			if wireType != 2 {
				return fmt.Errorf("proto: wrong wireType = %d for field ParamKey", wireType)
			}
			var byteLen int
			for shift := uint(0); ; shift += 7 {
				if shift >= 64 {
					return ErrIntOverflowGenesis
				}
				if iNdEx >= l {
					return io.ErrUnexpectedEOF
				}
				b := dAtA[iNdEx]
				iNdEx++
				byteLen |= int(b&0x7F) << shift
				if b < 0x80 {
					break
				}
			}
			if byteLen < 0 {
				return ErrInvalidLengthGenesis
			}
			postIndex := iNdEx + byteLen
			if postIndex < 0 || postIndex > l {
				return io.ErrUnexpectedEOF
			}
			m.ParamKey = append(m.ParamKey[:0], dAtA[iNdEx:postIndex]...)
			iNdEx = postIndex
		case 3:
			if wireType != 2 {
				return fmt.Errorf("proto: wrong wireType = %d for field Creator", wireType)
			}
			var stringLen uint64
			for shift := uint(0); ; shift += 7 {
				if shift >= 64 {
					return ErrIntOverflowGenesis
				}
				if iNdEx >= l {
					return io.ErrUnexpectedEOF
				}
				b := dAtA[iNdEx]
				iNdEx++
				stringLen |= uint64(b&0x7F) << shift
				if b < 0x80 {
					break
				}
			}
			intStringLen := int(stringLen)
			if intStringLen < 0 {
				return ErrInvalidLengthGenesis
			}
			postIndex := iNdEx + intStringLen
			if postIndex < 0 || postIndex > l {
				return io.ErrUnexpectedEOF
			}
			m.Creator = string(dAtA[iNdEx:postIndex])
			iNdEx = postIndex
		case 4:
			if wireType != 2 {
				return fmt.Errorf("proto: wrong wireType = %d for field ParamBytes", wireType)
			}
			var byteLen int
			for shift := uint(0); ; shift += 7 {
				if shift >= 64 {
					return ErrIntOverflowGenesis
				}
				if iNdEx >= l {
					return io.ErrUnexpectedEOF
				}
				b := dAtA[iNdEx]
				iNdEx++
				byteLen |= int(b&0x7F) << shift
				if b < 0x80 {
					break
				}
			}
			if byteLen < 0 {
				return ErrInvalidLengthGenesis
			}
			postIndex := iNdEx + byteLen
			if postIndex < 0 || postIndex > l {
				return io.ErrUnexpectedEOF
			}
			m.ParamBytes = append(m.ParamBytes[:0], dAtA[iNdEx:postIndex]...)
			iNdEx = postIndex
		default:
			iNdEx = preIndex
			skippy, err := skipGenesis(dAtA[iNdEx:])
			if err != nil {
				return err
			}
			if skippy < 0 || iNdEx+skippy < 0 {
				return ErrInvalidLengthGenesis
			}
			if iNdEx+skippy > l {
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

// silence unused import if math_bits not needed in some builds
var _ = math_bits.Len64
