//go:build !v64

package app

import (
	sdk "github.com/cosmos/cosmos-sdk/types"

	v63 "github.com/terpnetwork/terp-core/v6/app/upgrades/v6_3"
)

// armHasherNext schedules v6.4 on the apply block and keeps dest stores
// copied while that plan is armed. Not linked into the v6.4 ELF.
func (app *TerpApp) armHasherNext(ctx sdk.Context) error {
	if err := v63.MaybeArmNext(ctx, app.UpgradeKeeper); err != nil {
		return err
	}
	return v63.SyncDestWhileArmed(ctx, &app.AppKeepers)
}
