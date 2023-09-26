package app

import (
	errorsmod "cosmossdk.io/errors"
	storetypes "github.com/cosmos/cosmos-sdk/store/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
	sdkerrors "github.com/cosmos/cosmos-sdk/types/errors"

	"github.com/cosmos/cosmos-sdk/codec"
	"github.com/cosmos/cosmos-sdk/x/auth/ante"
	govkeeper "github.com/cosmos/cosmos-sdk/x/gov/keeper"
	stakingkeeper "github.com/cosmos/cosmos-sdk/x/staking/keeper"
	ibcante "github.com/cosmos/ibc-go/v7/modules/core/ante"
	"github.com/cosmos/ibc-go/v7/modules/core/keeper"

	feeshareante "github.com/terpnetwork/terp-core/v2/x/feeshare/ante"
	feesharekeeper "github.com/terpnetwork/terp-core/v2/x/feeshare/keeper"
	globalfeeante "github.com/terpnetwork/terp-core/v2/x/globalfee/ante"
	globalfeekeeper "github.com/terpnetwork/terp-core/v2/x/globalfee/keeper"

	wasmkeeper "github.com/CosmWasm/wasmd/x/wasm/keeper"
	wasmTypes "github.com/CosmWasm/wasmd/x/wasm/types"
)

// Lower back to 1 mil after https://github.com/cosmos/relayer/issues/1255
const maxBypassMinFeeMsgGasUsage = 2_000_000

// HandlerOptions extend the SDK's AnteHandler options by requiring the IBC
// channel keeper.
type HandlerOptions struct {
	ante.HandlerOptions

	GovKeeper         govkeeper.Keeper
	IBCKeeper         *keeper.Keeper
	FeeShareKeeper    feesharekeeper.Keeper
	BankKeeperFork    feeshareante.BankKeeper
	WasmConfig        *wasmTypes.WasmConfig
	TXCounterStoreKey storetypes.StoreKey
	Cdc               codec.BinaryCodec

	BypassMinFeeMsgTypes []string

	GlobalFeeKeeper globalfeekeeper.Keeper
	StakingKeeper   stakingkeeper.Keeper

	TxEncoder sdk.TxEncoder
}

func NewAnteHandler(options HandlerOptions) (sdk.AnteHandler, error) {
	if options.AccountKeeper == nil {
		return nil, errorsmod.Wrap(sdkerrors.ErrLogic, "account keeper is required for AnteHandler")
	}
	if options.BankKeeper == nil {
		return nil, errorsmod.Wrap(sdkerrors.ErrLogic, "bank keeper is required for AnteHandler")
	}
	if options.SignModeHandler == nil {
		return nil, errorsmod.Wrap(sdkerrors.ErrLogic, "sign mode handler is required for ante builder")
	}
	if options.WasmConfig == nil {
		return nil, errorsmod.Wrap(sdkerrors.ErrLogic, "wasm config is required for ante builder")
	}
	if options.TXCounterStoreKey == nil {
		return nil, errorsmod.Wrap(sdkerrors.ErrLogic, "tx counter key is required for ante builder")
	}

	sigGasConsumer := options.SigGasConsumer
	if sigGasConsumer == nil {
		sigGasConsumer = ante.DefaultSigVerificationGasConsumer
	}

	anteDecorators := []sdk.AnteDecorator{
		ante.NewSetUpContextDecorator(), // outermost AnteDecorator. SetUpContext must be called first
		wasmkeeper.NewLimitSimulationGasDecorator(options.WasmConfig.SimulationGasLimit), // after setup context to enforce limits early
		wasmkeeper.NewCountTXDecorator(options.TXCounterStoreKey),
		ante.NewExtensionOptionsDecorator(options.ExtensionOptionChecker),
		ante.NewValidateBasicDecorator(),
		ante.NewTxTimeoutHeightDecorator(),
		ante.NewValidateMemoDecorator(options.AccountKeeper),
		ante.NewConsumeGasForTxSizeDecorator(options.AccountKeeper),
		globalfeeante.NewFeeDecorator(options.BypassMinFeeMsgTypes, options.GlobalFeeKeeper, options.StakingKeeper, maxBypassMinFeeMsgGasUsage),
		ante.NewDeductFeeDecorator(options.AccountKeeper, options.BankKeeper, options.FeegrantKeeper, options.TxFeeChecker),
		feeshareante.NewFeeSharePayoutDecorator(options.BankKeeperFork, options.FeeShareKeeper),
		ante.NewSetPubKeyDecorator(options.AccountKeeper), // SetPubKeyDecorator must be called before all signature verification decorators
		ante.NewValidateSigCountDecorator(options.AccountKeeper),
		ante.NewSigGasConsumeDecorator(options.AccountKeeper, options.SigGasConsumer),
		ante.NewSigVerificationDecorator(options.AccountKeeper, options.SignModeHandler),
		ante.NewIncrementSequenceDecorator(options.AccountKeeper),
		ibcante.NewRedundantRelayDecorator(options.IBCKeeper),
	}

	return sdk.ChainAnteDecorators(anteDecorators...), nil
}
