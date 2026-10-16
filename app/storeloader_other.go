//go:build v64 || v63pre

package app

import (
	"github.com/cosmos/cosmos-sdk/baseapp"
	storetypes "github.com/cosmos/cosmos-sdk/store/v2/types"
	upgradetypes "github.com/cosmos/cosmos-sdk/x/upgrade/types"
)

func upgradeStoreLoader(height int64, storeUpgrades *storetypes.StoreUpgrades, _ string) baseapp.StoreLoader {
	return upgradetypes.UpgradeStoreLoader(height, storeUpgrades)
}
