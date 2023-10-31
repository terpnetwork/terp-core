package app

import (
	wasmtypes "github.com/CosmWasm/wasmd/x/wasm/types"
)

const (
	// DefaultTerpInstanceCost is initially set the same as in wasmd
	DefaultTerpInstanceCost uint64 = 60_000
	// DefaultTerpCompileCost set to a large number for testing
	DefaultTerpCompileCost uint64 = 3
)

// TerpGasRegisterConfig is defaults plus a custom compile amount
func TerpGasRegisterConfig() wasmtypes.WasmGasRegisterConfig {
	gasConfig := wasmtypes.DefaultGasRegisterConfig()
	gasConfig.InstanceCost = DefaultTerpInstanceCost
	gasConfig.CompileCost = DefaultTerpCompileCost

	return gasConfig
}

func NewTerpWasmGasRegister() wasmtypes.WasmGasRegister {
	return wasmtypes.NewWasmGasRegister(TerpGasRegisterConfig())
}
