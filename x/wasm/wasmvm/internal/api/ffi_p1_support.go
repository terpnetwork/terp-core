package api

/*
#include "bindings.h"
*/
import "C"

import (
	"unsafe"

	"github.com/CosmWasm/wasmvm/v3/types"
)

const (
	goErrNone        = int32(C.GoError_None)
	goErrPanic       = int32(C.GoError_Panic)
	goErrBadArgument = int32(C.GoError_BadArgument)
	goErrOutOfGas    = int32(C.GoError_OutOfGas)
	goErrUser        = int32(C.GoError_User)
)

func classifyPanic(v any) int32 {
	var ret C.GoError
	func() {
		defer recoverPanic(&ret)
		panic(v)
	}()
	return int32(ret)
}

func u8ViewFromBytes(s []byte) C.U8SliceView {
	if s == nil {
		return C.U8SliceView{is_none: true, ptr: cu8_ptr(nil), len: cusize(0)}
	}
	if len(s) == 0 {
		return C.U8SliceView{is_none: false, ptr: cu8_ptr(nil), len: cusize(0)}
	}
	return C.U8SliceView{
		is_none: false,
		ptr:     cu8_ptr(unsafe.Pointer(&s[0])),
		len:     cusize(len(s)),
	}
}

func copyU8SliceFromBytes(s []byte) []byte {
	return copyU8Slice(u8ViewFromBytes(s))
}

func copyU8SliceNilPtrNonzero() {
	_ = copyU8Slice(C.U8SliceView{is_none: false, ptr: cu8_ptr(nil), len: cusize(4)})
}

func copyUnmanagedNone() []byte {
	return copyAndDestroyUnmanagedVector(constructUnmanagedVector(cbool(true), cu8_ptr(nil), 0, 0))
}

func copyUnmanagedEmpty() []byte {
	return copyAndDestroyUnmanagedVector(constructUnmanagedVector(cbool(false), cu8_ptr(nil), 0, 0))
}

func copyUnmanagedLenGtCap() {
	_ = copyAndDestroyUnmanagedVector(constructUnmanagedVector(cbool(false), cu8_ptr(nil), cusize(8), cusize(1)))
}

func cGetOOGUsedGas() (int32, uint64) {
	gasMeter := NewMockGasMeter(1)
	store := NewLookup(gasMeter)
	var kv types.KVStore = store
	gm := types.GasMeter(gasMeter)
	used := cu64(0)
	val := newUnmanagedVector(nil)
	errOut := newUnmanagedVector(nil)
	ret := cGet(
		(*C.db_t)(unsafe.Pointer(&kv)),
		(*C.gas_meter_t)(unsafe.Pointer(&gm)),
		&used,
		u8ViewFromBytes([]byte("missing")),
		&val,
		&errOut,
	)
	return int32(ret), uint64(used)
}

func cNextWithIterator(it types.Iterator, iteratorIDOverride uint64) (int32, []byte) {
	callID := startCall()
	defer endCall(callID)
	var id uint64
	if it != nil {
		var err error
		id, err = storeIterator(callID, it, frameLenLimit)
		if err != nil {
			panic(err)
		}
	} else {
		id = iteratorIDOverride
	}
	gasMeter := NewMockGasMeter(500_000_000_000)
	gm := types.GasMeter(gasMeter)
	used := cu64(0)
	key := newUnmanagedVector(nil)
	val := newUnmanagedVector(nil)
	errOut := newUnmanagedVector(nil)
	ref := C.IteratorReference{call_id: cu64(callID), iterator_id: cu64(id)}
	ret := cNext(ref, (*C.gas_meter_t)(unsafe.Pointer(&gm)), &used, &key, &val, &errOut)
	msg := copyAndDestroyUnmanagedVector(errOut)
	return int32(ret), msg
}
