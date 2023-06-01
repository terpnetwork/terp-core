package app

import (
	"github.com/cosmos/cosmos-sdk/baseapp"
	authkeeper "github.com/cosmos/cosmos-sdk/x/auth/keeper"
	bankkeeper "github.com/cosmos/cosmos-sdk/x/bank/keeper"
	capabilitykeeper "github.com/cosmos/cosmos-sdk/x/capability/keeper"
	stakingkeeper "github.com/cosmos/cosmos-sdk/x/staking/keeper"
	ibckeeper "github.com/cosmos/ibc-go/v7/modules/core/keeper"

	"github.com/terpnetwork/terp-core/x/wasm"
)

func (app *TerpApp) GetIBCKeeper() *ibckeeper.Keeper {
	return app.IBCKeeper
}

func (app *TerpApp) GetScopedIBCKeeper() capabilitykeeper.ScopedKeeper {
	return app.ScopedIBCKeeper
}

func (app *TerpApp) GetBaseApp() *baseapp.BaseApp {
	return app.BaseApp
}

func (app *TerpApp) GetBankKeeper() bankkeeper.Keeper {
	return app.BankKeeper
}

func (app *TerpApp) GetStakingKeeper() *stakingkeeper.Keeper {
	return app.StakingKeeper
}

func (app *TerpApp) GetAccountKeeper() authkeeper.AccountKeeper {
	return app.AccountKeeper
}

func (app *TerpApp) GetWasmKeeper() wasm.Keeper {
	return app.WasmKeeper
}
