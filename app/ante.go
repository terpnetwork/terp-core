package app

import (
	corestoretypes "cosmossdk.io/core/store"
	errorsmod "cosmossdk.io/errors"
	sdk "github.com/cosmos/cosmos-sdk/types"
	sdkerrors "github.com/cosmos/cosmos-sdk/types/errors"

	"github.com/cosmos/cosmos-sdk/codec"
	"github.com/cosmos/cosmos-sdk/x/auth/ante"
	stakingkeeper "github.com/cosmos/cosmos-sdk/x/staking/keeper"
	ibcante "github.com/cosmos/ibc-go/v10/modules/core/ante"
	"github.com/cosmos/ibc-go/v10/modules/core/keeper"
	smartaccountante "github.com/terpnetwork/terp-core/v5/x/smart-account/ante"

	feeshareante "github.com/terpnetwork/terp-core/v5/x/feeshare/ante"
	feesharekeeper "github.com/terpnetwork/terp-core/v5/x/feeshare/keeper"
	globalfeekeeper "github.com/terpnetwork/terp-core/v5/x/globalfee/keeper"
	smartaccountkeeper "github.com/terpnetwork/terp-core/v5/x/smart-account/keeper"

	wasmkeeper "github.com/CosmWasm/wasmd/x/wasm/keeper"
	wasmTypes "github.com/CosmWasm/wasmd/x/wasm/types"
)

// Lower back to 1 mil after https://github.com/cosmos/relayer/issues/1255
const maxBypassMinFeeMsgGasUsage = 2_000_000

// HandlerOptions extend the SDK's AnteHandler options by requiring the IBC
// channel keeper.
type HandlerOptions struct {
	ante.HandlerOptions
	SmartAccount      *smartaccountkeeper.Keeper
	IBCKeeper         *keeper.Keeper
	FeeShareKeeper    *feesharekeeper.Keeper
	BankKeeperFork    feeshareante.BankKeeper
	WasmConfig        *wasmTypes.NodeConfig
	TXCounterStoreKey corestoretypes.KVStoreService
	Cdc               codec.Codec

	BypassMinFeeMsgTypes []string

	GlobalFeeKeeper *globalfeekeeper.Keeper
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

	if options.TXCounterStoreKey == nil {
		return nil, errorsmod.Wrap(sdkerrors.ErrLogic, "tx counter key is required for ante builder")
	}

	sigGasConsumer := options.SigGasConsumer
	if sigGasConsumer == nil {
		sigGasConsumer = ante.DefaultSigVerificationGasConsumer
	}

	deductFeeDecorator := ante.NewDeductFeeDecorator(options.AccountKeeper, options.BankKeeper, options.FeegrantKeeper, options.TxFeeChecker)

	classicSignatureVerificationDecorator := sdk.ChainAnteDecorators(
		deductFeeDecorator,
		ante.NewSetPubKeyDecorator(options.AccountKeeper),
		ante.NewValidateSigCountDecorator(options.AccountKeeper),
		ante.NewSigGasConsumeDecorator(options.AccountKeeper, sigGasConsumer),
		ante.NewSigVerificationDecorator(options.AccountKeeper, options.SignModeHandler),
		ante.NewIncrementSequenceDecorator(options.AccountKeeper),
		ibcante.NewRedundantRelayDecorator(options.IBCKeeper),
	)
	authenticatorVerificationDecorator := sdk.ChainAnteDecorators(
		smartaccountante.NewEmitPubKeyDecoratorEvents(options.AccountKeeper),
		ante.NewValidateSigCountDecorator(options.AccountKeeper), // we can probably remove this as multisigs are not supported here
		// Both the signature verification, fee deduction, and gas consumption functionality
		// is embedded in the authenticator decorator
		smartaccountante.NewAuthenticatorDecorator(options.Cdc, options.SmartAccount, options.AccountKeeper, options.SignModeHandler, deductFeeDecorator),
		ante.NewIncrementSequenceDecorator(options.AccountKeeper),
	)

	anteDecorators := []sdk.AnteDecorator{
		ante.NewSetUpContextDecorator(),
		wasmkeeper.NewLimitSimulationGasDecorator(options.WasmConfig.SimulationGasLimit),
		wasmkeeper.NewCountTXDecorator(options.TXCounterStoreKey),
		ante.NewExtensionOptionsDecorator(options.ExtensionOptionChecker),
		ante.NewValidateBasicDecorator(),
		ante.NewTxTimeoutHeightDecorator(),
		ante.NewValidateMemoDecorator(options.AccountKeeper),
		ante.NewConsumeGasForTxSizeDecorator(options.AccountKeeper),
		smartaccountante.NewCircuitBreakerDecorator(
			options.SmartAccount,
			authenticatorVerificationDecorator,
			classicSignatureVerificationDecorator,
		),
	}

	return sdk.ChainAnteDecorators(anteDecorators...), nil
}
