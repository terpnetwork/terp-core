package params

const (
	// Name defines the application name of Terp network.
	Name = "terp"

	// BondDenom defines the native staking token denomination.
	BondDenom = "uterp"

	// DisplayDenom defines the name, symbol, and display value of the Juno token.
	DisplayBondDenom = "TERP"

	// BondDenom defines the native gas token denomination.
	GasDenom = "uthiol"

	// DisplayDenom defines the name, symbol, and display value of the Thiol token.
	DisplayGasDenom = "THIOL"

	// DefaultGasLimit - set to the same value as cosmos-sdk flags.DefaultGasLimit
	// this value is currently only used in tests.
	DefaultGasLimit = 200000
)
