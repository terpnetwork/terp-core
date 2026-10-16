//go:build !v64 && !v63pre

package app

import (
	"github.com/cosmos/cosmos-sdk/baseapp"
	storetypes "github.com/cosmos/cosmos-sdk/store/v2/types"
	upgradetypes "github.com/cosmos/cosmos-sdk/x/upgrade/types"

	v63 "github.com/terpnetwork/terp-core/v6/app/upgrades/v6_3"
)

func upgradeStoreLoader(height int64, storeUpgrades *storetypes.StoreUpgrades, name string) baseapp.StoreLoader {
	if name == v63.UpgradeName {
		return v63.StoreLoader(height, storeUpgrades)
	}
	return upgradetypes.UpgradeStoreLoader(height, storeUpgrades)
}
