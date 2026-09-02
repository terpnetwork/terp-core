package types

import (
	"fmt"

	sdk "github.com/cosmos/cosmos-sdk/types"
)

// NewParams creates a new Params instance
func NewParams() Params {
	return Params{
		MaximumUnauthenticatedGas: 120_000,
		IsSmartAccountActive:      true,
		CircuitBreakerControllers: []string{},
	}
}

// DefaultParams returns a default set of parameters
func DefaultParams() Params {
	return NewParams()
}

// Validate validates the set of params
func (p Params) Validate() error {
	err := validateMaximumUnauthenticatedGas(p.MaximumUnauthenticatedGas)
	if err != nil {
		return err
	}

	err = validateIsSmartAccountActive(p.IsSmartAccountActive)
	if err != nil {
		return err
	}

	err = validateCircuitBreakerControllers(p.CircuitBreakerControllers)
	if err != nil {
		return err
	}

	return nil
}

// Validate Default Gas Reduction
func validateMaximumUnauthenticatedGas(i interface{}) error {
	// Convert the given parameter to a uint64.
	_, ok := i.(uint64)
	if !ok {
		return fmt.Errorf("invalid parameter type: %T", i)
	}

	return nil
}

func validateIsSmartAccountActive(i interface{}) error {
	// Convert the given parameter to a bool.
	_, ok := i.(bool)
	if !ok {
		return fmt.Errorf("invalid parameter type: %T", i)
	}

	return nil
}

func validateCircuitBreakerControllers(i interface{}) error {
	// Convert the given parameter to a []string.
	controllers, ok := i.([]string)
	if !ok {
		return fmt.Errorf("invalid parameter type: %T", i)
	}

	// each string in the array should be a valid address
	for _, addr := range controllers {
		_, err := sdk.AccAddressFromBech32(addr)
		if err != nil {
			return fmt.Errorf("invalid address: %s", addr)
		}
	}

	return nil
}
