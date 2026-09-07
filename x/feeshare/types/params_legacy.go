package types

// TODO: Remove this and params_legacy_test.go after v0.47.x (v16) upgrade

import (
	"cosmossdk.io/math"
)

// Parameter store key
var (
	DefaultEnableFeeShare  = true
	DefaultDeveloperShares = math.LegacyNewDecWithPrec(50, 2) // 50%
	DefaultAllowedDenoms   = []string(nil)                    // all allowed

	ParamStoreKeyEnableFeeShare  = []byte("EnableFeeShare")
	ParamStoreKeyDeveloperShares = []byte("DeveloperShares")
	ParamStoreKeyAllowedDenoms   = []byte("AllowedDenoms")
)
