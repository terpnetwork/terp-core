package types

import (
	"errors"
	"testing"

	errorsmod "cosmossdk.io/errors"
	wasmvmtypes "github.com/CosmWasm/wasmvm/types"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestWasmVMFlavouredError(t *testing.T) {
	myErr := ErrNoSuchCodeFn(1)
	specs := map[string]struct {
		exec func(t *testing.T)
	}{
		"IsOf": {
			exec: func(t *testing.T) {
				t.Helper()
				assert.True(t, errorsmod.IsOf(myErr, myErr.sdkErr))
				assert.Equal(t, myErr.sdkErr, myErr.Unwrap())
			},
		},
		"unwrapped": {
			exec: func(t *testing.T) {
				t.Helper()
				assert.Equal(t, myErr.sdkErr, myErr.Unwrap())
			},
		},
		"caused": {
			exec: func(t *testing.T) {
				t.Helper()
				assert.Equal(t, myErr.sdkErr, myErr.Cause())
			},
		},
		"wrapped supports WasmVMErrorable": {
			exec: func(t *testing.T) {
				t.Helper()
				var wasmvmErr WasmVMErrorable
				require.True(t, errors.As(myErr.Wrap("my description"), &wasmvmErr))
				gotErr := wasmvmErr.ToWasmVMError()
				assert.Equal(t, wasmvmtypes.NoSuchCode{CodeID: 1}, gotErr)
			},
		},
		"wrappedf supports WasmVMErrorable": {
			exec: func(t *testing.T) {
				t.Helper()
				var wasmvmErr WasmVMErrorable
				require.True(t, errors.As(myErr.Wrapf("my description: %d", 1), &wasmvmErr))
				gotErr := wasmvmErr.ToWasmVMError()
				assert.Equal(t, wasmvmtypes.NoSuchCode{CodeID: 1}, gotErr)
			},
		},
		"supports WasmVMErrorable": {
			exec: func(t *testing.T) {
				t.Helper()
				var wasmvmErr WasmVMErrorable
				require.True(t, errors.As(myErr, &wasmvmErr))
				gotErr := wasmvmErr.ToWasmVMError()
				assert.Equal(t, wasmvmtypes.NoSuchCode{CodeID: 1}, gotErr)
			},
		},
		"fallback to sdk error when wasmvm error unset": {
			exec: func(t *testing.T) {
				t.Helper()
				var wasmvmErr WasmVMErrorable
				require.True(t, errors.As(WasmVMFlavouredError{sdkErr: ErrEmpty}, &wasmvmErr))
				gotErr := wasmvmErr.ToWasmVMError()
				assert.Equal(t, ErrEmpty, gotErr)
			},
		},
		"abci info": {
			exec: func(t *testing.T) {
				t.Helper()
				codespace, code, log := errorsmod.ABCIInfo(myErr, false)
				assert.Equal(t, DefaultCodespace, codespace)
				assert.Equal(t, uint32(28), code)
				assert.Equal(t, "no such code", log)
			},
		},
		"abci info - wrapped": {
			exec: func(t *testing.T) {
				t.Helper()
				codespace, code, log := errorsmod.ABCIInfo(myErr.Wrap("my description"), false)
				assert.Equal(t, DefaultCodespace, codespace)
				assert.Equal(t, uint32(28), code)
				assert.Equal(t, "my description: no such code", log)
			},
		},
	}
	for name, spec := range specs {
		t.Run(name, spec.exec)
	}
}
