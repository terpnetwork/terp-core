package v6_1

import (
	sdk "github.com/cosmos/cosmos-sdk/types"
	upgradekeeper "github.com/cosmos/cosmos-sdk/x/upgrade/keeper"
	upgradetypes "github.com/cosmos/cosmos-sdk/x/upgrade/types"
)

const FollowupPlan = "v6.2"

// FollowupPlanInfo is a URL, not inline binaries JSON. v6.1 must not bake
// v6.2 ELF checksums (those do not exist until the v6.2 pack is published).
// Cosmovisor ParseInfo GETs this object; checksums live in that JSON.
const FollowupPlanInfo = "https://s3.terp.network/upgrades/v6.2/cosmovisor.json"

// MaybeArmV62 schedules plan v6.2 two blocks after v6.1 is applied.
// ApplyUpgrade clears any plan the handler writes, so this runs from EndBlocker.
func MaybeArmV62(ctx sdk.Context, k *upgradekeeper.Keeper) error {
	if k == nil {
		return nil
	}
	done, err := k.GetDoneHeight(ctx, UpgradeName)
	if err != nil || done == 0 || done != ctx.BlockHeight() {
		return nil
	}
	if _, err := k.GetUpgradePlan(ctx); err == nil {
		return nil
	}
	next := ctx.BlockHeight() + 2
	if err := k.ScheduleUpgrade(ctx, upgradetypes.Plan{
		Name:   FollowupPlan,
		Height: next,
		Info:   FollowupPlanInfo,
	}); err != nil {
		return err
	}
	ctx.Logger().Info("v6.1: armed plan v6.2", "height", next, "info", FollowupPlanInfo)
	return nil
}
