package types

import (
	"context"

	"cosmossdk.io/math"
	sdk "github.com/cosmos/cosmos-sdk/types"
	stakingtypes "github.com/cosmos/cosmos-sdk/x/staking/types"
)

// BankKeeper defines the bank module interface needed by hashmerchant.
type BankKeeper interface {
	SendCoinsFromAccountToModule(ctx context.Context, senderAddr sdk.AccAddress, recipientModule string, amt sdk.Coins) error
	SendCoinsFromModuleToAccount(ctx context.Context, senderModule string, recipientAddr sdk.AccAddress, amt sdk.Coins) error
	GetBalance(ctx context.Context, addr sdk.AccAddress, denom string) sdk.Coin
}

// AccountKeeper defines the auth module interface needed by hashmerchant.
type AccountKeeper interface {
	GetModuleAddress(moduleName string) sdk.AccAddress
	GetModuleAccount(ctx context.Context, moduleName string) sdk.ModuleAccountI
}

// StakingKeeper defines the staking module interface needed for quorum checks.
type StakingKeeper interface {
	GetBondedValidatorsByPower(ctx context.Context) ([]stakingtypes.Validator, error)
	TotalBondedTokens(ctx context.Context) (math.Int, error)
}

// WasmKeeper defines the CosmWasm module interface for sudo dispatch.
type WasmKeeper interface {
	Sudo(ctx context.Context, contractAddress sdk.AccAddress, msg []byte) ([]byte, error)
}
