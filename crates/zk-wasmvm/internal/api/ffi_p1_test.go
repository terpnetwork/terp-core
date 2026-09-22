package api

import (
	"errors"
	"os"
	"sync"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestRecoverPanicGasKinds(t *testing.T) {
	require.Equal(t, goErrOutOfGas, classifyPanic(ErrorOutOfGas{Descriptor: "get"}))
	require.Equal(t, goErrOutOfGas, classifyPanic(ErrorGasOverflow{Descriptor: "add"}))
	require.Equal(t, goErrOutOfGas, classifyPanic(ErrorNegativeGasConsumed{Descriptor: "refund"}))
	require.Equal(t, goErrBadArgument, classifyPanic(ffiBoundError("len>cap")))
	require.Equal(t, goErrPanic, classifyPanic("plain string"))
}

func TestCopyU8SliceEmptyAndNil(t *testing.T) {
	require.Nil(t, copyU8SliceFromBytes(nil))
	empty := copyU8SliceFromBytes([]byte{})
	require.NotNil(t, empty)
	require.Equal(t, 0, len(empty))
	require.Equal(t, []byte("hi"), copyU8SliceFromBytes([]byte("hi")))
}

func TestCopyU8SliceRejectsNilPtrNonzeroLen(t *testing.T) {
	require.Panics(t, copyU8SliceNilPtrNonzero)
}

func TestCopyAndDestroyUnmanagedVectorLenCap(t *testing.T) {
	require.Nil(t, copyUnmanagedNone())
	out := copyUnmanagedEmpty()
	require.Equal(t, 0, len(out))
}

func TestCopyAndDestroyUnmanagedVectorRejectsLenGtCap(t *testing.T) {
	require.Panics(t, copyUnmanagedLenGtCap)
}

func TestAccountUsedGasOnOutOfGasGet(t *testing.T) {
	ret, used := cGetOOGUsedGas()
	require.Equal(t, goErrOutOfGas, ret)
	require.Greater(t, used, uint64(0))
}

type errIter struct {
	err error
}

func (e errIter) Domain() ([]byte, []byte) { return nil, nil }
func (e errIter) Valid() bool              { return true }
func (e errIter) Next()                    {}
func (e errIter) Key() []byte              { return []byte("k") }
func (e errIter) Value() []byte            { return []byte("v") }
func (e errIter) Error() error             { return e.err }
func (e errIter) Close() error             { return nil }

func TestCNextHonorsIteratorError(t *testing.T) {
	ret, msg := cNextWithIterator(errIter{err: errors.New("iter boom")}, 0)
	require.Equal(t, goErrUser, ret)
	require.Equal(t, "iter boom", string(msg))
}

func TestCNextNilIteratorIsBadArgument(t *testing.T) {
	ret, _ := cNextWithIterator(nil, 99)
	require.Equal(t, goErrBadArgument, ret)
}

func TestConcurrentStoreCode(t *testing.T) {
	cache, cleanup := withCache(t)
	defer cleanup()
	wasm, err := os.ReadFile("../../testdata/hackatom.wasm")
	require.NoError(t, err)

	var wg sync.WaitGroup
	errCh := make(chan error, 8)
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, e := StoreCode(cache, wasm, false)
			errCh <- e
		}()
	}
	wg.Wait()
	close(errCh)
	for e := range errCh {
		require.NoError(t, e)
	}
}
