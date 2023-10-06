package app

import (
	wasmkeeper "github.com/CosmWasm/wasmd/x/wasm/keeper"
)

const (
	// DefaultTerpInstanceCost is initially set the same as in wasmd
	DefaultTerpInstanceCost uint64 = 60_000
	// DefaultTerpCompileCost set to a large number for testing
	DefaultTerpCompileCost uint64 = 3
)

// TerpGasRegisterConfig is defaults plus a custom compile amount
func TerpGasRegisterConfig() wasmkeeper.WasmGasRegisterConfig {
	gasConfig := wasmkeeper.DefaultGasRegisterConfig()
	gasConfig.InstanceCost = DefaultTerpInstanceCost
	gasConfig.CompileCost = DefaultTerpCompileCost

	return gasConfig
}

func NewTerpWasmGasRegister() wasmkeeper.WasmGasRegister {
	return wasmkeeper.NewWasmGasRegister(TerpGasRegisterConfig())
}
