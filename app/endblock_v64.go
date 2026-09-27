//go:build v64

package app

import sdk "github.com/cosmos/cosmos-sdk/types"

// armHasherNext is a no-op on the v6.4 ELF. Halt height is the plan v6.3
// already scheduled. This binary does not read that height to arm another plan.
func (app *TerpApp) armHasherNext(sdk.Context) error {
	return nil
}
