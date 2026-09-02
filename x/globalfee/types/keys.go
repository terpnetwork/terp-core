package types

var (
	ParamsKey = []byte{0x00}

	// ParamStoreKeyMinGasPrices is the legacy x/params key for MinimumGasPrices.
	ParamStoreKeyMinGasPrices = []byte("MinimumGasPricesParam")
)

const (
	// ModuleName is the name of the this module
	ModuleName = "globalfee"

	StoreKey = ModuleName

	QuerierRoute = ModuleName
)
