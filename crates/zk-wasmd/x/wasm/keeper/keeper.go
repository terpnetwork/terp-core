package keeper

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"math"
	"reflect"
	"strconv"
	"strings"
	"time"

	wasmvm "github.com/CosmWasm/wasmvm/v3"
	wasmvmtypes "github.com/CosmWasm/wasmvm/v3/types"
	channeltypes "github.com/cosmos/ibc-go/v11/modules/core/04-channel/types"

	"cosmossdk.io/collections"
	corestoretypes "cosmossdk.io/core/store"
	errorsmod "cosmossdk.io/errors"
	"cosmossdk.io/log/v2"

	"github.com/cosmos/cosmos-sdk/codec"
	"github.com/cosmos/cosmos-sdk/runtime"
	"github.com/cosmos/cosmos-sdk/store/v2/prefix"
	storetypes "github.com/cosmos/cosmos-sdk/store/v2/types"
	"github.com/cosmos/cosmos-sdk/telemetry"
	sdk "github.com/cosmos/cosmos-sdk/types"
	sdkerrors "github.com/cosmos/cosmos-sdk/types/errors"
	authtypes "github.com/cosmos/cosmos-sdk/x/auth/types"
	vestingexported "github.com/cosmos/cosmos-sdk/x/auth/vesting/exported"
	stakingtypes "github.com/cosmos/cosmos-sdk/x/staking/types"

	"github.com/CosmWasm/wasmd/x/wasm/ioutils"
	"github.com/CosmWasm/wasmd/x/wasm/types"
)

// contractMemoryLimit is the memory limit of each contract execution (in MiB)
// constant value so all nodes run with the same limit.
const contractMemoryLimit = 32

// Option is an extension point to instantiate keeper with non default values
type Option interface {
	apply(*Keeper)
}

// WasmVMQueryHandler is an extension point for custom query handler implementations
type WasmVMQueryHandler interface {
	// HandleQuery executes the requested query
	HandleQuery(ctx sdk.Context, caller sdk.AccAddress, request wasmvmtypes.QueryRequest) ([]byte, error)
}

type CoinTransferrer interface {
	// TransferCoins sends the coin amounts from the source to the destination with rules applied.
	TransferCoins(ctx sdk.Context, fromAddr, toAddr sdk.AccAddress, amt sdk.Coins) error
}

// AccountPruner handles the balances and data cleanup for accounts that are pruned on contract instantiate.
// This is an extension point to attach custom logic
type AccountPruner interface {
	// CleanupExistingAccount handles the cleanup process for balances and data of the given account. The persisted account
	// type is already reset to base account at this stage.
	// The method returns true when the account address can be reused. Unsupported account types are rejected by returning false
	CleanupExistingAccount(ctx sdk.Context, existingAccount sdk.AccountI) (handled bool, err error)
}

// WasmVMResponseHandler is an extension point to handles the response data returned by a contract call.
type WasmVMResponseHandler interface {
	// Handle processes the data returned by a contract invocation.
	Handle(
		ctx sdk.Context,
		contractAddr sdk.AccAddress,
		ibcPort string,
		messages []wasmvmtypes.SubMsg,
		origRspData []byte,
	) ([]byte, error)
}

// list of account types that are accepted for wasm contracts. Chains importing wasmd
// can overwrite this list with the WithAcceptedAccountTypesOnContractInstantiation option.
var defaultAcceptedAccountTypes = map[reflect.Type]struct{}{
	reflect.TypeFor[*authtypes.BaseAccount](): {},
}

// Keeper will have a reference to Wasm Engine with it's own data directory.
type Keeper struct {
	// The (unexposed) keys used to access the stores from the Context.
	storeService          corestoretypes.KVStoreService
	cdc                   codec.Codec
	accountKeeper         types.AccountKeeper
	bank                  CoinTransferrer
	wasmVM                types.WasmEngine
	wasmVMQueryHandler    WasmVMQueryHandler
	wasmVMResponseHandler WasmVMResponseHandler
	messenger             Messenger
	// queryGasLimit is the max wasmvm gas that can be spent on executing a query with a contract
	queryGasLimit        uint64
	gasRegister          types.GasRegister
	maxQueryStackSize    uint32
	maxCallDepth         uint32
	acceptedAccountTypes map[reflect.Type]struct{}
	accountPruner        AccountPruner
	params               collections.Item[types.Params]
	// circuitDepositees is address -> paid_until unix. One extra CircuitUploadAccess path.
	circuitDepositees    collections.Map[sdk.AccAddress, uint64]
	circuitDepositYearly sdk.Coin
	bankKeeper           types.BankKeeper
	stakingKeeper        types.StakingKeeper
	// circuitWeight, if set, returns participation weight for a bonded validator
	// at settle (0 = skip / reallocate). nil => 1 if !Jailed else 0.
	circuitWeight func(ctx context.Context, v stakingtypes.Validator) int64
	// propagate gov authZ to sub-messages
	propagateGovAuthorization map[types.AuthorizationPolicyAction]struct{}

	// the address capable of executing a MsgUpdateParams message. Typically, this
	// should be the x/gov module account.
	authority string

	// txHash is a function to calculate the transaction hash from the raw transaction bytes.
	// This is used to provide the transaction hash to the wasmvm engine and currently defaults to
	// sha256 hashing, which is the hash currently used in CometBFT:
	// https://github.com/cometbft/cometbft/blob/v1.0.1/crypto/tmhash/hash.go#L19-L22
	txHash func([]byte) []byte

	// wasmLimits contains the limits sent to wasmvm on init
	wasmLimits wasmvmtypes.WasmLimits
}

// GetVkInfo implements [types.ViewKeeper].
// VKs are addressed via CircuitInfo (zk_id); this is an alias for GetCircuitInfo.
func (k Keeper) GetVkInfo(ctx context.Context, vkID uint64) *types.CircuitInfo {
	return k.GetCircuitInfo(ctx, vkID)
}

// GetVk implements [types.ViewKeeper].
// Returns the reconstructed circuit blob (params+cs+vk) from wasmvm when available.
func (k Keeper) GetVk(ctx context.Context, vkID uint64) ([]byte, error) {
	return k.GetCircuit(ctx, vkID)
}

// GetVkParam deliberately does not expose raw param bytes over the public
// ViewKeeper surface. Params remain available only for internal reconstruction.
func (k Keeper) GetVkParam(_ context.Context, _ uint64) ([]byte, error) {
	return nil, errorsmod.Wrap(types.ErrInvalid, "raw param bytes are not queryable; use VkParamInfo for checksums and metadata")
}

// GetVkParamInfo returns param metadata (checksums / creator). Never raw bytes.
func (k Keeper) GetVkParamInfo(ctx context.Context, vkParamID uint64) *types.VkParamInfoResponse {
	store := k.storeService.OpenKVStore(ctx)
	var vkParamInfo types.VkParamInfoResponse
	vkParamInfoBz, err := store.Get(types.GetVkParamId(vkParamID))
	if err != nil || vkParamInfoBz == nil {
		return nil
	}
	k.cdc.MustUnmarshal(vkParamInfoBz, &vkParamInfo)
	return &vkParamInfo
}

// getVkParamBytes loads raw param bytes for internal circuit reconstruction only.
// Must not be wired to any public query path.
func (k Keeper) getVkParamBytes(ctx context.Context, vkParamID uint64) ([]byte, error) {
	store := k.storeService.OpenKVStore(ctx)
	bz, err := store.Get(types.GetVkParamBytesKey(vkParamID))
	if err != nil {
		return nil, err
	}
	if bz == nil {
		return nil, types.ErrNotFound.Wrapf("vk param bytes %d", vkParamID)
	}
	return bz, nil
}

func (k Keeper) getUploadAccessConfig(ctx context.Context) types.AccessConfig {
	return k.GetParams(ctx).CodeUploadAccess
}

func (k Keeper) getInstantiateAccessConfig(ctx context.Context) types.AccessType {
	return k.GetParams(ctx).InstantiateDefaultPermission
}

func (k Keeper) GetWasmLimits() wasmvmtypes.WasmLimits {
	return k.wasmLimits
}

// GetParams returns the total set of wasm parameters.
func (k Keeper) GetParams(ctx context.Context) types.Params {
	p, err := k.params.Get(ctx)
	if err != nil {
		panic(err)
	}
	return p
}

// SetParams sets all wasm parameters.
func (k Keeper) SetParams(ctx context.Context, ps types.Params) error {
	return k.params.Set(ctx, ps)
}

// GetAuthority returns the x/wasm module's authority.
func (k Keeper) GetAuthority() string {
	return k.authority
}

// GetGasRegister returns the x/wasm module's gas register.
func (k Keeper) GetGasRegister() types.GasRegister {
	return k.gasRegister
}

func (k Keeper) create_with_circuit(ctx context.Context, creator sdk.AccAddress, wasmCode, vkCode []byte, instantiateAccess *types.AccessConfig, authZ types.AuthorizationPolicy) (codeID uint64, zkID uint64, checksums [][]byte, err error) {
	if creator == nil {
		return 0, 0, nil, errorsmod.Wrap(sdkerrors.ErrInvalidAddress, "cannot be nil")
	}
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	// figure out proper instantiate access
	defaultAccessConfig := k.getInstantiateAccessConfig(sdkCtx).With(creator)
	if instantiateAccess == nil {
		instantiateAccess = &defaultAccessConfig
	}
	chainConfigs := types.ChainAccessConfigs{
		Instantiate: defaultAccessConfig,
		Upload:      k.getUploadAccessConfig(sdkCtx),
	}

	if !authZ.CanCreateCode(chainConfigs, creator, *instantiateAccess) {
		return 0, 0, nil, errorsmod.Wrap(sdkerrors.ErrUnauthorized, "can not create code")
	}

	if ioutils.IsGzip(wasmCode) {
		sdkCtx.GasMeter().ConsumeGas(k.gasRegister.UncompressCosts(len(wasmCode)), "Uncompress gzip bytecode")
		wasmCode, err = ioutils.Uncompress(wasmCode, int64(types.MaxWasmSize))
		if err != nil {
			return 0, 0, nil, types.ErrCreateFailed.Wrap(errorsmod.Wrap(err, "uncompress wasm archive").Error())
		}
	}

	gasLeft := k.runtimeGasForContract(sdkCtx)
	var gasUsed, totalGasUsed uint64
	isSimulation := sdkCtx.ExecMode() == sdk.ExecModeSimulate
	var vmChecksums []wasmvm.Checksum
	var wasmChecksum wasmvm.Checksum

	if isSimulation {
		wasmChecksum, gasUsed, err = k.wasmVM.SimulateStoreCode(wasmCode, gasLeft)
	} else {
		wasmChecksum, gasUsed, err = k.wasmVM.StoreCode(wasmCode, gasLeft)
	}
	totalGasUsed += gasUsed
	if err != nil {
		k.consumeRuntimeGas(sdkCtx, totalGasUsed)
		return 0, 0, nil, errorsmod.Wrap(types.ErrCreateFailed, err.Error())
	}

	// Step 2: Store Circuit (if provided)
	var circuitChecksum wasmvm.Checksum
	if vkCode != nil {
		gasLeft = k.runtimeGasForContract(sdkCtx)
		if isSimulation {
			circuitChecksum, gasUsed, err = k.wasmVM.SimulateStoreCircuit(vkCode, gasLeft)
		} else {
			circuitChecksum, gasUsed, err = k.wasmVM.StoreCircuit(vkCode, gasLeft)
		}
		totalGasUsed += gasUsed
		if err != nil {
			k.consumeRuntimeGas(sdkCtx, totalGasUsed)
			return 0, 0, nil, errorsmod.Wrap(types.ErrCreateFailed, err.Error())
		}
		vmChecksums = []wasmvm.Checksum{wasmChecksum, circuitChecksum}
	} else {
		// If no circuit provided, still return array but with empty second element
		vmChecksums = []wasmvm.Checksum{wasmChecksum, wasmvm.Checksum(nil)}
	}

	k.consumeRuntimeGas(sdkCtx, totalGasUsed)

	// Validate checksums - must have at least 2 checksums (wasm + circuit)
	if len(vmChecksums) < 2 {
		return 0, 0, nil, types.ErrCreateFailed.Wrap("expected 2 checksums (wasm + circuit), got " + string(rune(len(vmChecksums))))
	}

	// Convert checksums from wasmvm format
	checksums = make([][]byte, 2)
	checksums[0] = []byte(vmChecksums[0]) // WASM checksum
	checksums[1] = []byte(vmChecksums[1]) // Circuit checksum

	// Validate checksum lengths
	if len(checksums[0]) != 32 {
		return 0, 0, nil, types.ErrCreateFailed.Wrap("invalid wasm checksum length: expected 32, got " + strconv.Itoa(len(checksums[0])))
	}
	if len(checksums[1]) == 0 {
		return 0, 0, nil, types.ErrCreateFailed.Wrap("circuit key is empty")
	}
	// Path A identity is CircuitFooter::to_circuit_key (72), not SHA-256.
	if len(checksums[1]) != wasmvm.CircuitKeyLen {
		return 0, 0, nil, types.ErrCreateFailed.Wrap("invalid circuit key length: expected 72, got " + strconv.Itoa(len(checksums[1])))
	}

	// simulation gets default value for capabilities
	var requiredCapabilities string
	if !isSimulation {
		report, err := k.wasmVM.AnalyzeCode(wasmvmtypes.Checksum(checksums[0]))
		if err != nil {
			return 0, 0, nil, errorsmod.Wrap(types.ErrCreateFailed, err.Error())
		}
		requiredCapabilities = report.RequiredCapabilities
	}
	codeID = k.mustAutoIncrementID(sdkCtx, types.KeySequenceCodeID)
	zkIDUint32 := k.mustAutoIncrementIDUint32(sdkCtx, types.KeySequenceCircuitID)
	k.Logger(sdkCtx).Debug("storing new contract with vk", "capabilities", requiredCapabilities, "code_id", codeID, "zk_id", zkIDUint32)
	codeInfo := types.NewCodeInfo(checksums[0], creator, *instantiateAccess)
	vkInfo := types.NewCircuitInfo(checksums[1], creator, *instantiateAccess)
	k.mustStoreCodeInfo(sdkCtx, codeID, codeInfo)
	k.mustStoreCircuitInfo(sdkCtx, uint64(zkIDUint32), vkInfo)
	if err := k.setCircuitCreatorIndex(sdkCtx, creator, uint64(zkIDUint32)); err != nil {
		return 0, 0, nil, err
	}

	// Canonical app-state blob by zk_id (same discipline as store_circuit).
	if err := k.mustStoreCircuitBytes(sdkCtx, uint64(zkIDUint32), vkCode); err != nil {
		return 0, 0, nil, err
	}

	evt := sdk.NewEvent(
		types.EventTypeStoreCodeWithCircuit,
		sdk.NewAttribute(types.AttributeKeyChecksum, hex.EncodeToString(checksums[0])),
		sdk.NewAttribute(types.AttributeKeyCircuitChecksum, hex.EncodeToString(checksums[1])),
		sdk.NewAttribute(types.AttributeKeyCodeID, strconv.FormatUint(codeID, 10)),
		sdk.NewAttribute(types.AttributeKeyZkID, strconv.FormatUint(uint64(zkIDUint32), 10)),
	)
	for f := range strings.SplitSeq(requiredCapabilities, ",") {
		evt.AppendAttributes(sdk.NewAttribute(types.AttributeKeyRequiredCapability, strings.TrimSpace(f)))
	}
	sdkCtx.EventManager().EmitEvent(evt)

	return codeID, zkID, checksums, nil
}

// create stores only WASM code (legacy path, no circuit support)
func (k Keeper) create(ctx context.Context, creator sdk.AccAddress, wasmCode []byte, instantiateAccess *types.AccessConfig, authZ types.AuthorizationPolicy) (codeID uint64, checksum []byte, err error) {
	if creator == nil {
		return 0, checksum, errorsmod.Wrap(sdkerrors.ErrInvalidAddress, "cannot be nil")
	}
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	// figure out proper instantiate access
	defaultAccessConfig := k.getInstantiateAccessConfig(sdkCtx).With(creator)
	if instantiateAccess == nil {
		instantiateAccess = &defaultAccessConfig
	}
	chainConfigs := types.ChainAccessConfigs{
		Instantiate: defaultAccessConfig,
		Upload:      k.getUploadAccessConfig(sdkCtx),
	}

	if !authZ.CanCreateCode(chainConfigs, creator, *instantiateAccess) {
		return 0, checksum, errorsmod.Wrap(sdkerrors.ErrUnauthorized, "can not create code")
	}

	if ioutils.IsGzip(wasmCode) {
		sdkCtx.GasMeter().ConsumeGas(k.gasRegister.UncompressCosts(len(wasmCode)), "Uncompress gzip bytecode")
		wasmCode, err = ioutils.Uncompress(wasmCode, int64(types.MaxWasmSize))
		if err != nil {
			return 0, checksum, types.ErrCreateFailed.Wrap(errorsmod.Wrap(err, "uncompress wasm archive").Error())
		}
	}

	gasLeft := k.runtimeGasForContract(sdkCtx)
	var gasUsed uint64
	isSimulation := sdkCtx.ExecMode() == sdk.ExecModeSimulate
	if isSimulation {
		// only simulate storing the code, no files are written
		checksum, gasUsed, err = k.wasmVM.SimulateStoreCode(wasmCode, gasLeft)
	} else {
		checksum, gasUsed, err = k.wasmVM.StoreCode(wasmCode, gasLeft)
	}
	k.consumeRuntimeGas(sdkCtx, gasUsed)
	if err != nil {
		return 0, checksum, errorsmod.Wrap(types.ErrCreateFailed, err.Error())
	}
	// simulation gets default value for capabilities
	var requiredCapabilities string
	if !isSimulation {
		report, err := k.wasmVM.AnalyzeCode(checksum)
		if err != nil {
			return 0, checksum, errorsmod.Wrap(types.ErrCreateFailed, err.Error())
		}
		requiredCapabilities = report.RequiredCapabilities
	}
	codeID = k.mustAutoIncrementID(sdkCtx, types.KeySequenceCodeID)
	k.Logger(sdkCtx).Debug("storing new contract", "capabilities", requiredCapabilities, "code_id", codeID)
	codeInfo := types.NewCodeInfo(checksum, creator, *instantiateAccess)
	k.mustStoreCodeInfo(sdkCtx, codeID, codeInfo)

	evt := sdk.NewEvent(
		types.EventTypeStoreCode,
		sdk.NewAttribute(types.AttributeKeyChecksum, hex.EncodeToString(checksum)),
		sdk.NewAttribute(types.AttributeKeyCodeID, strconv.FormatUint(codeID, 10)), // last element to be compatible with scripts
	)
	for _, f := range strings.Split(requiredCapabilities, ",") {
		evt.AppendAttributes(sdk.NewAttribute(types.AttributeKeyRequiredCapability, strings.TrimSpace(f)))
	}
	sdkCtx.EventManager().EmitEvent(evt)

	return codeID, checksum, nil
}

// store_vk_param stores reusable commitment params.
// Raw bytes are written to an internal key; public queries only expose metadata.
func (k Keeper) store_vk_param(
	ctx context.Context,
	creator sdk.AccAddress,
	auth *types.CircuitParamAuth,
	paramBytes []byte,
	authZ types.AuthorizationPolicy,
) (paramID uint64, checksum []byte, err error) {
	if creator == nil {
		return 0, nil, errorsmod.Wrap(sdkerrors.ErrInvalidAddress, "cannot be nil")
	}
	if auth == nil {
		return 0, nil, errorsmod.Wrap(sdkerrors.ErrInvalidRequest, "circuit param auth is required")
	}
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	defaultAccessConfig := k.getInstantiateAccessConfig(sdkCtx).With(creator)
	if err := k.authorizeCircuitUpload(sdkCtx, creator, &defaultAccessConfig, authZ); err != nil {
		return 0, nil, errorsmod.Wrap(err, "can not store vk params")
	}

	if ioutils.IsGzip(paramBytes) {
		sdkCtx.GasMeter().ConsumeGas(k.gasRegister.UncompressCosts(len(paramBytes)), "Uncompress gzip param bytes")
		paramBytes, err = ioutils.Uncompress(paramBytes, int64(types.MaxCircuitSize))
		if err != nil {
			return 0, nil, types.ErrCreateFailed.Wrap(errorsmod.Wrap(err, "uncompress param archive").Error())
		}
	}
	if len(paramBytes) == 0 {
		return 0, nil, errorsmod.Wrap(sdkerrors.ErrInvalidRequest, "empty param bytes")
	}

	// Populate wasmvm zk_param/ + pinned CachedParam. Returns 36-byte param_key:
	// [appstate_key_le 4][sha256(params) 32]. Idempotent if the file already exists.
	paramKey, err := k.wasmVM.StoreParam(paramBytes)
	if err != nil {
		return 0, nil, errorsmod.Wrap(types.ErrCreateFailed, err.Error())
	}
	if len(paramKey) != 36 {
		return 0, nil, types.ErrCreateFailed.Wrapf("StoreParam returned %d-byte key, want 36", len(paramKey))
	}
	// Return value for MsgStoreVkParamResponse: prefer full param_key so clients
	// can match circuit footers without recomputing appstate_key.
	checksum = paramKey

	paramID = k.mustAutoIncrementID(sdkCtx, types.KeySequenceVkParamID)
	// DataHash holds the full 36-byte param_key (not bare 32-byte sha256) for cold-path reconstruction.
	info := types.NewVkParamInfo(paramID, paramKey, creator)
	k.mustStoreVkParamInfo(sdkCtx, paramID, info)

	// Canonical app-state blob for genesis / state sync (queries never expose this).
	store := k.storeService.OpenKVStore(sdkCtx)
	if err := store.Set(types.GetVkParamBytesKey(paramID), paramBytes); err != nil {
		return 0, nil, err
	}

	// Gas: size-based meter + wasmvm write (StoreParam has no separate gas return yet).
	sdkCtx.GasMeter().ConsumeGas(k.gasRegister.UncompressCosts(len(paramBytes)), "store vk params")

	k.Logger(sdkCtx).Debug("storing new vk params",
		"param_id", paramID,
		"k", auth.K,
		"circuit_type", auth.CircuitType,
		"curve_type", auth.CurveType,
		"param_len", len(paramBytes),
		"param_key", hex.EncodeToString(paramKey),
	)

	sdkCtx.EventManager().EmitEvent(sdk.NewEvent(
		types.EventTypeStoreVkParam,
		sdk.NewAttribute(types.AttributeKeyParamID, strconv.FormatUint(paramID, 10)),
		sdk.NewAttribute(types.AttributeKeyParamChecksum, hex.EncodeToString(paramKey)),
	))

	return paramID, checksum, nil
}

// store_circuit stores a VK (cs+vk[+footer]) that references previously uploaded params.
// paramID is the sequential app-state id from StoreVkParam (MsgStoreCircuit.param_key).
// vkBody is expected to be [cs][vk][footer] OR a full monolithic [params][cs][vk][footer]
// when params are already included (legacy full-blob path with paramID=0 is not used here).
func (k Keeper) store_circuit(
	ctx context.Context,
	creator sdk.AccAddress,
	paramID uint64,
	vkBody []byte,
	instantiateAccess *types.AccessConfig,
	authZ types.AuthorizationPolicy,
) (zkID uint64, checksum []byte, err error) {
	if creator == nil {
		return 0, checksum, errorsmod.Wrap(sdkerrors.ErrInvalidAddress, "cannot be nil")
	}
	if paramID == 0 {
		return 0, checksum, errorsmod.Wrap(sdkerrors.ErrInvalidRequest, "param_key is required")
	}
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	defaultAccessConfig := k.getInstantiateAccessConfig(sdkCtx).With(creator)
	if instantiateAccess == nil {
		instantiateAccess = &defaultAccessConfig
	}
	if err := k.authorizeCircuitUpload(sdkCtx, creator, instantiateAccess, authZ); err != nil {
		return 0, checksum, errorsmod.Wrap(err, "can not create circuit")
	}

	paramInfo := k.GetVkParamInfo(sdkCtx, paramID)
	if paramInfo == nil {
		return 0, checksum, types.ErrNotFound.Wrapf("vk param %d", paramID)
	}
	paramBytes, err := k.getVkParamBytes(sdkCtx, paramID)
	if err != nil {
		return 0, checksum, err
	}
	// Integrity vs stored key: DataHash is the 36-byte param_key (last 32 = sha256).
	sum := sha256.Sum256(paramBytes)
	switch len(paramInfo.DataHash) {
	case 36:
		if !bytes.Equal(sum[:], paramInfo.DataHash[4:]) {
			return 0, checksum, types.ErrInvalid.Wrap("stored param bytes do not match param_key checksum")
		}
	case 32:
		// legacy metadata stored bare sha256 only
		if !bytes.Equal(sum[:], paramInfo.DataHash) {
			return 0, checksum, types.ErrInvalid.Wrap("stored param bytes do not match param checksum")
		}
	default:
		return 0, checksum, types.ErrInvalid.Wrapf("unexpected param key length %d", len(paramInfo.DataHash))
	}
	// Ensure wasmvm zk_param/ + pinned cache are warm (idempotent if already present).
	if _, err := k.wasmVM.StoreParam(paramBytes); err != nil {
		return 0, checksum, errorsmod.Wrap(types.ErrCreateFailed, err.Error())
	}

	if ioutils.IsGzip(vkBody) {
		sdkCtx.GasMeter().ConsumeGas(k.gasRegister.UncompressCosts(len(vkBody)), "Uncompress gzip vk body")
		vkBody, err = ioutils.Uncompress(vkBody, int64(types.MaxCircuitSize))
		if err != nil {
			return 0, checksum, types.ErrCreateFailed.Wrap(errorsmod.Wrap(err, "uncompress vk body").Error())
		}
	}
	if len(vkBody) == 0 {
		return 0, checksum, errorsmod.Wrap(sdkerrors.ErrInvalidRequest, "empty vk_body")
	}

	// Reconstruct monolithic circuit blob for wasmvm: [params][cs+vk+footer]
	// Callers must supply vk_body such that concatenation yields a valid footer layout
	// (param_len / checksums matching the stored params).
	circuitBinary := make([]byte, 0, len(paramBytes)+len(vkBody))
	circuitBinary = append(circuitBinary, paramBytes...)
	circuitBinary = append(circuitBinary, vkBody...)

	gasLeft := k.runtimeGasForContract(sdkCtx)
	var gasUsed uint64
	isSimulation := sdkCtx.ExecMode() == sdk.ExecModeSimulate
	var vmChecksum wasmvm.Checksum
	if isSimulation {
		vmChecksum, gasUsed, err = k.wasmVM.SimulateStoreCircuit(circuitBinary, gasLeft)
	} else {
		vmChecksum, gasUsed, err = k.wasmVM.StoreCircuit(circuitBinary, gasLeft)
	}
	k.consumeRuntimeGas(sdkCtx, gasUsed)
	if err != nil {
		return 0, checksum, errorsmod.Wrap(types.ErrCreateFailed, err.Error())
	}
	checksum = []byte(vmChecksum)
	// Circuit key is the wasmvm Path A key (typically 72 bytes). Store it once
	// in CircuitInfo so CircuitInfo queries stay pure KV lookups.
	if len(checksum) == 0 {
		return 0, checksum, types.ErrCreateFailed.Wrap("empty circuit key from wasmvm")
	}

	zkID = k.mustAutoIncrementID(sdkCtx, types.KeySequenceCircuitID)
	zkInfo := types.NewCircuitInfoWithLayout(
		checksum,
		creator,
		*instantiateAccess,
		0,
		uint64(len(paramBytes)),
		0, // cs_len filled by clients via footer; optional metadata
		uint64(len(vkBody)),
	)
	k.mustStoreCircuitInfo(sdkCtx, zkID, zkInfo)
	k.mustStoreCircuitParamRef(sdkCtx, zkID, paramID)
	if err := k.setCircuitCreatorIndex(sdkCtx, creator, zkID); err != nil {
		return 0, checksum, err
	}
	// Canonical app-state blob for genesis / state sync / cold-path WasmQuery::Circuit.
	// Hot path never reads this — Path A uses CircuitHash + wasmvm cache only.
	if err := k.mustStoreCircuitBytes(sdkCtx, zkID, circuitBinary); err != nil {
		return 0, checksum, err
	}

	k.Logger(sdkCtx).Debug("storing new circuit",
		"zk_id", zkID,
		"param_id", paramID,
		"circuit_key", hex.EncodeToString(checksum),
		"circuit_key_len", len(checksum),
		"param_len", len(paramBytes),
		"vk_body_len", len(vkBody),
		"blob_len", len(circuitBinary),
	)

	sdkCtx.EventManager().EmitEvent(sdk.NewEvent(
		types.EventTypeStoreCircuit,
		sdk.NewAttribute(types.AttributeKeyCircuitChecksum, hex.EncodeToString(checksum)),
		sdk.NewAttribute(types.AttributeKeyZkID, strconv.FormatUint(zkID, 10)),
		sdk.NewAttribute(types.AttributeKeyParamID, strconv.FormatUint(paramID, 10)),
		sdk.NewAttribute(types.AttributeKeyParamChecksum, hex.EncodeToString(paramInfo.DataHash)),
	))

	return zkID, checksum, nil
}

// store_full_circuit is a convenience: StoreVkParam then StoreCircuit.
func (k Keeper) store_full_circuit(
	ctx context.Context,
	creator sdk.AccAddress,
	auth *types.CircuitParamAuth,
	paramBytes, vkBody []byte,
	authZ types.AuthorizationPolicy,
) (paramID, zkID uint64, paramChecksum, circuitChecksum []byte, err error) {
	paramID, paramChecksum, err = k.store_vk_param(ctx, creator, auth, paramBytes, authZ)
	if err != nil {
		return 0, 0, nil, nil, err
	}
	zkID, circuitChecksum, err = k.store_circuit(ctx, creator, paramID, vkBody, nil, authZ)
	if err != nil {
		return 0, 0, nil, nil, err
	}
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	sdkCtx.EventManager().EmitEvent(sdk.NewEvent(
		types.EventTypeStoreFullCircuit,
		sdk.NewAttribute(types.AttributeKeyParamID, strconv.FormatUint(paramID, 10)),
		sdk.NewAttribute(types.AttributeKeyZkID, strconv.FormatUint(zkID, 10)),
		sdk.NewAttribute(types.AttributeKeyParamChecksum, hex.EncodeToString(paramChecksum)),
		sdk.NewAttribute(types.AttributeKeyCircuitChecksum, hex.EncodeToString(circuitChecksum)),
	))
	return paramID, zkID, paramChecksum, circuitChecksum, nil
}

// authorizeCircuitUpload is CircuitUploadAccess OR an unexpired depositee row.
// Gov / Everybody / allowlisted addresses skip payment.
func (k Keeper) authorizeCircuitUpload(ctx sdk.Context, creator sdk.AccAddress, instantiateAccess *types.AccessConfig, authZ types.AuthorizationPolicy) error {
	defaultAccessConfig := k.getInstantiateAccessConfig(ctx).With(creator)
	if instantiateAccess == nil {
		instantiateAccess = &defaultAccessConfig
	}
	chainConfigs := types.ChainAccessConfigs{
		Instantiate: defaultAccessConfig,
		Upload:      k.getCircuitUploadAccessConfig(ctx),
	}
	if authZ.CanCreateCode(chainConfigs, creator, *instantiateAccess) {
		return nil
	}
	if !instantiateAccess.IsSubset(defaultAccessConfig) {
		return sdkerrors.ErrUnauthorized
	}
	if k.HasCircuitDeposit(ctx, creator) {
		return nil
	}
	return types.ErrCircuitDepositRequired
}

func (k Keeper) HasCircuitDeposit(ctx context.Context, addr sdk.AccAddress) bool {
	until, err := k.circuitDepositees.Get(ctx, addr)
	if err != nil {
		return false
	}
	now := sdk.UnwrapSDKContext(ctx).BlockTime().Unix()
	if now < 0 {
		now = 0
	}
	return int64(until) > now
}

var _ types.CircuitDepositQueryServer = (*Keeper)(nil)

func (k Keeper) Deposit(goCtx context.Context, req *types.QueryCircuitDepositRequest) (*types.QueryCircuitDepositResponse, error) {
	if req == nil || req.Address == "" {
		return nil, sdkerrors.ErrInvalidAddress
	}
	addr, err := sdk.AccAddressFromBech32(req.Address)
	if err != nil {
		return nil, err
	}
	until, ok := k.CircuitDepositPaidUntil(goCtx, addr)
	covered := k.HasCircuitDeposit(goCtx, addr)
	if !ok {
		until = 0
	}
	return &types.QueryCircuitDepositResponse{
		Address:       req.Address,
		PaidUntilUnix: int64(until),
		Covered:       covered,
	}, nil
}

func (k Keeper) CircuitDepositPaidUntil(ctx context.Context, addr sdk.AccAddress) (uint64, bool) {
	until, err := k.circuitDepositees.Get(ctx, addr)
	if err != nil {
		return 0, false
	}
	return until, true
}

func (k Keeper) PayCircuitDeposit(ctx context.Context, payer sdk.AccAddress, years uint32) (int64, error) {
	if years == 0 || years > types.CircuitDepositMaxYears {
		return 0, types.ErrLimit.Wrapf("years must be 1..%d", types.CircuitDepositMaxYears)
	}
	fee := k.circuitDepositYearly
	if !fee.IsPositive() {
		fee = sdk.NewInt64Coin(sdk.DefaultBondDenom, types.CircuitDepositYearlyAmount)
	}
	amt := sdk.NewCoins(sdk.NewCoin(fee.Denom, fee.Amount.MulRaw(int64(years))))
	if err := k.receiveCircuitRunwayPayment(ctx, payer, amt); err != nil {
		return 0, err
	}
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	now := sdkCtx.BlockTime().Unix()
	if now < 0 {
		now = 0
	}
	start := uint64(now)
	if existing, err := k.circuitDepositees.Get(ctx, payer); err == nil {
		k.deleteCircuitDepositExpiry(ctx, existing, payer)
		if existing > start {
			start = existing
		}
	}
	until := start + uint64(years)*uint64(types.CircuitDepositSecondsPerYear)
	if err := k.circuitDepositees.Set(ctx, payer, until); err != nil {
		return 0, err
	}
	if err := k.setCircuitDepositExpiry(ctx, until, payer); err != nil {
		return 0, err
	}
	k.deleteCircuitDepositGC(ctx, payer)
	sdkCtx.EventManager().EmitEvent(sdk.NewEvent(
		"pay_circuit_deposit",
		sdk.NewAttribute("payer", payer.String()),
		sdk.NewAttribute("years", strconv.FormatUint(uint64(years), 10)),
		sdk.NewAttribute("paid_until_unix", strconv.FormatUint(until, 10)),
	))
	return int64(until), nil
}

func (k Keeper) getCircuitUploadAccessConfig(ctx context.Context) types.AccessConfig {
	p := k.GetParams(ctx)
	// Prefer dedicated circuit upload policy when set; fall back to code upload.
	if p.CircuitUploadAccess.Permission != types.AccessTypeUnspecified {
		return p.CircuitUploadAccess
	}
	return p.CodeUploadAccess
}

func (k Keeper) mustStoreVkParamInfo(ctx context.Context, paramID uint64, info types.VkParamInfoResponse) {
	store := k.storeService.OpenKVStore(ctx)
	if err := store.Set(types.GetVkParamId(paramID), k.cdc.MustMarshal(&info)); err != nil {
		panic(err)
	}
}

// CircuitParamRefPrefix maps zk_id -> param_id (uint64 BE).
var circuitParamRefPrefix = []byte{0x17}

func (k Keeper) mustStoreCircuitParamRef(ctx context.Context, zkID, paramID uint64) {
	store := k.storeService.OpenKVStore(ctx)
	key := append(append([]byte{}, circuitParamRefPrefix...), sdk.Uint64ToBigEndian(zkID)...)
	if err := store.Set(key, sdk.Uint64ToBigEndian(paramID)); err != nil {
		panic(err)
	}
}

// GetCircuitParamID returns the param_id referenced by a circuit, if recorded.
func (k Keeper) GetCircuitParamID(ctx context.Context, zkID uint64) (uint64, bool) {
	store := k.storeService.OpenKVStore(ctx)
	key := append(append([]byte{}, circuitParamRefPrefix...), sdk.Uint64ToBigEndian(zkID)...)
	bz, err := store.Get(key)
	if err != nil || bz == nil || len(bz) != 8 {
		return 0, false
	}
	return sdk.BigEndianToUint64(bz), true
}

func (k Keeper) mustStoreCodeInfo(ctx context.Context, codeID uint64, codeInfo types.CodeInfo) {
	store := k.storeService.OpenKVStore(ctx)
	// 0x01 | codeID (uint64) -> ContractInfo
	err := store.Set(types.GetCodeKey(codeID), k.cdc.MustMarshal(&codeInfo))
	if err != nil {
		panic(err)
	}
}

func (k Keeper) mustStoreCircuitInfo(ctx context.Context, vkID uint64, circuitInfo types.CircuitInfo) {
	store := k.storeService.OpenKVStore(ctx)
	// 0x16 | zkID (uint64) -> CircuitInfo (includes CircuitHash / 72-byte Path A key)
	err := store.Set(types.GetCircuitKey(vkID), k.cdc.MustMarshal(&circuitInfo))
	if err != nil {
		panic(err)
	}
}

// mustStoreCircuitBytes persists the monolithic circuit blob as canonical chain state.
// Used for genesis export, state sync, and cold-path queries — not the proof hot path.
func (k Keeper) mustStoreCircuitBytes(ctx context.Context, zkID uint64, blob []byte) error {
	store := k.storeService.OpenKVStore(ctx)
	return store.Set(types.GetCircuitBytesKey(zkID), blob)
}

// removeCircuit deletes app-state circuit metadata + blob and unpins the wasmvm entry.
// Mirrors RemoveCode's unpin discipline so PinnedMemoryCache does not retain dead weight.
func (k Keeper) removeCircuit(ctx context.Context, zkID uint64) error {
	zkInfo := k.GetCircuitInfo(ctx, zkID)
	if zkInfo == nil {
		return types.ErrNoSuchCircuitFn(zkID).Wrapf("zk id %d", zkID)
	}

	sdkCtx := sdk.UnwrapSDKContext(ctx)
	// Always unpin while CircuitHash is still available (no-op if not pinned).
	if err := k.wasmVM.UnpinCircuit(zkInfo.CircuitHash); err != nil {
		k.Logger(sdkCtx).Debug("wasmvm UnpinCircuit during remove", "zk_id", zkID, "err", err)
	}
	store := k.storeService.OpenKVStore(ctx)
	_ = store.Delete(types.GetPinnedCircuitIndexPrefix(zkID))

	// Drop compiled/cached entry when the engine supports full remove.
	if rem, ok := k.wasmVM.(interface {
		RemoveCircuit(checksum wasmvm.Checksum) error
	}); ok {
		if err := rem.RemoveCircuit(zkInfo.CircuitHash); err != nil {
			k.Logger(sdkCtx).Debug("wasmvm RemoveCircuit", "err", err)
		}
	}

	if creator, err := sdk.AccAddressFromBech32(zkInfo.Creator); err == nil {
		k.deleteCircuitCreatorIndex(ctx, creator, zkID)
	}
	if err := store.Delete(types.GetCircuitKey(zkID)); err != nil {
		return err
	}
	if err := store.Delete(types.GetCircuitBytesKey(zkID)); err != nil {
		return err
	}
	paramRefKey := append(append([]byte{}, circuitParamRefPrefix...), sdk.Uint64ToBigEndian(zkID)...)
	_ = store.Delete(paramRefKey)

	sdkCtx.EventManager().EmitEvent(sdk.NewEvent(
		types.EventTypeUnpinCircuit,
		sdk.NewAttribute(types.AttributeKeyZkID, strconv.FormatUint(zkID, 10)),
		sdk.NewAttribute(types.AttributeKeyCircuitChecksum, hex.EncodeToString(zkInfo.CircuitHash)),
	))
	return nil
}

func (k Keeper) importCode(ctx context.Context, codeID uint64, codeInfo types.CodeInfo, wasmCode []byte) error {
	if ioutils.IsGzip(wasmCode) {
		var err error
		wasmCode, err = ioutils.Uncompress(wasmCode, math.MaxInt64)
		if err != nil {
			return types.ErrCreateFailed.Wrap(errorsmod.Wrap(err, "uncompress wasm archive").Error())
		}
	}
	newCodeHash, err := k.wasmVM.StoreCodeUnchecked(wasmCode)
	if err != nil {
		return errorsmod.Wrap(types.ErrCreateFailed, err.Error())
	}
	if !bytes.Equal(codeInfo.CodeHash, newCodeHash) {
		return errorsmod.Wrap(types.ErrInvalid, "code hashes not same")
	}

	store := k.storeService.OpenKVStore(ctx)
	key := types.GetCodeKey(codeID)
	ok, err := store.Has(key)
	if err != nil {
		return errorsmod.Wrap(err, "has code-id key")
	}
	if ok {
		return errorsmod.Wrapf(types.ErrDuplicate, "duplicate code: %d", codeID)
	}
	// 0x01 | codeID (uint64) -> ContractInfo
	return store.Set(key, k.cdc.MustMarshal(&codeInfo))
}

// cosmwasm circuit footer size for dual param/vk checksum layout.
const cosmwasmFooterLength = 80

func (k Keeper) importCircuit(ctx context.Context, zkID uint64, zkInfo types.CircuitInfo, zkBinary []byte) error {
	if ioutils.IsGzip(zkBinary) {
		var err error
		zkBinary, err = ioutils.Uncompress(zkBinary, math.MaxInt64)
		if err != nil {
			return types.ErrCreateFailed.Wrap(errorsmod.Wrap(err, "uncompress wasm archive").Error())
		}
	}

	// Genesis integrity: params in the blob must produce the param_key the circuit expects.
	// Catch mismatch here instead of at first proof verification.
	if err := validateCircuitParamAlignment(zkBinary, zkInfo); err != nil {
		return errorsmod.Wrapf(err, "circuit zk_id %d param alignment", zkID)
	}

	// Warm standalone param cache from the monolithic blob when layout is known.
	// store_param is idempotent if zk_param/{key}.bin already exists.
	if paramBytes, ok := circuitParamBytes(zkBinary, zkInfo); ok {
		paramKey, err := k.wasmVM.StoreParam(paramBytes)
		if err != nil {
			return errorsmod.Wrap(types.ErrCreateFailed, err.Error())
		}
		if err := assertParamKeyMatchesCircuit(paramKey, zkInfo.CircuitHash); err != nil {
			return errorsmod.Wrapf(err, "circuit zk_id %d after StoreParam", zkID)
		}
	}

	newCircuitHash, err := k.wasmVM.StoreCircuitUnchecked(zkBinary)
	if err != nil {
		return errorsmod.Wrap(types.ErrCreateFailed, err.Error())
	}
	if !bytes.Equal(zkInfo.CircuitHash, newCircuitHash) {
		return errorsmod.Wrap(types.ErrInvalid, "circuit hash not same")
	}

	store := k.storeService.OpenKVStore(ctx)
	key := types.GetCircuitKey(zkID)
	ok, err := store.Has(key)
	if err != nil {
		return errorsmod.Wrap(err, "has zk-id key")
	}
	if ok {
		return errorsmod.Wrapf(types.ErrDuplicate, "duplicate circuit: %d", zkID)
	}
	// Metadata + canonical blob (for export / cold path after import).
	if err := store.Set(key, k.cdc.MustMarshal(&zkInfo)); err != nil {
		return err
	}
	return k.mustStoreCircuitBytes(ctx, zkID, zkBinary)
}

// importVkParam restores a standalone param set (genesis / state sync).
func (k Keeper) importVkParam(ctx context.Context, paramID uint64, info types.VkParamInfoResponse, paramBytes []byte) error {
	if len(paramBytes) == 0 {
		return errorsmod.Wrap(types.ErrInvalid, "empty param bytes")
	}
	paramKey, err := k.wasmVM.StoreParam(paramBytes)
	if err != nil {
		return errorsmod.Wrap(types.ErrCreateFailed, err.Error())
	}
	if len(paramKey) != 36 {
		return errorsmod.Wrapf(types.ErrInvalid, "StoreParam returned %d-byte key, want 36", len(paramKey))
	}
	// Genesis must declare the same key StoreParam derives (or leave empty to accept derived).
	if len(info.DataHash) == 0 {
		info.DataHash = paramKey
	} else if !bytes.Equal(paramKey, info.DataHash) {
		return errorsmod.Wrapf(types.ErrInvalid,
			"param_id %d: StoreParam key %x does not match genesis param_key %x",
			paramID, paramKey, info.DataHash)
	}
	info.VkID = paramID
	k.mustStoreVkParamInfo(ctx, paramID, info)
	store := k.storeService.OpenKVStore(ctx)
	return store.Set(types.GetVkParamBytesKey(paramID), paramBytes)
}

// circuitParamBytes returns the param slice from a monolithic circuit blob.
func circuitParamBytes(zkBinary []byte, zkInfo types.CircuitInfo) ([]byte, bool) {
	paramLen := int(zkInfo.VkpLen)
	if paramLen == 0 && len(zkBinary) >= cosmwasmFooterLength {
		// Fallback: footer param_len at bytes [len-footer+4 .. len-footer+8] LE
		footer := zkBinary[len(zkBinary)-cosmwasmFooterLength:]
		paramLen = int(binary.LittleEndian.Uint32(footer[4:8]))
	}
	if paramLen <= 0 || paramLen >= len(zkBinary) {
		return nil, false
	}
	return zkBinary[:paramLen], true
}

// validateCircuitParamAlignment checks SHA256(params) and (when possible) the
// 36-byte param_key half of the 72-byte circuit key.
func validateCircuitParamAlignment(zkBinary []byte, zkInfo types.CircuitInfo) error {
	paramBytes, ok := circuitParamBytes(zkBinary, zkInfo)
	if !ok {
		return nil // nothing to validate
	}
	sum := sha256.Sum256(paramBytes)

	// Footer dual-checksum layout: param_checksum is footer[16:48].
	if len(zkBinary) >= cosmwasmFooterLength {
		footer := zkBinary[len(zkBinary)-cosmwasmFooterLength:]
		footerParamChecksum := footer[16:48]
		if !bytes.Equal(sum[:], footerParamChecksum) {
			return fmt.Errorf(
				"param SHA256 %x != footer.param_checksum %x (blob will fail check_circuit)",
				sum[:], footerParamChecksum,
			)
		}
		// Footer param_len must match slice we used.
		footerParamLen := binary.LittleEndian.Uint32(footer[4:8])
		if int(footerParamLen) != len(paramBytes) {
			return fmt.Errorf(
				"param slice length %d != footer.param_len %d",
				len(paramBytes), footerParamLen,
			)
		}
	}

	// CircuitHash is [param_key 36][vk_key 36]; param_key[4:36] is param_checksum.
	if len(zkInfo.CircuitHash) >= 36 {
		keyParamChecksum := zkInfo.CircuitHash[4:36]
		if !bytes.Equal(sum[:], keyParamChecksum) {
			return fmt.Errorf(
				"param SHA256 %x != circuit_key param_checksum %x",
				sum[:], keyParamChecksum,
			)
		}
	}
	return nil
}

// assertParamKeyMatchesCircuit checks StoreParam's 36-byte key against the
// leading half of the 72-byte circuit key (param_key || vk_key).
func assertParamKeyMatchesCircuit(paramKey, circuitHash []byte) error {
	if len(paramKey) != 36 {
		return fmt.Errorf("param_key length %d, want 36", len(paramKey))
	}
	if len(circuitHash) < 36 {
		return nil // legacy short key — skip
	}
	if !bytes.Equal(paramKey, circuitHash[:36]) {
		return fmt.Errorf(
			"StoreParam key %x does not match circuit_key[:36] %x — params will not load for this circuit",
			paramKey, circuitHash[:36],
		)
	}
	return nil
}

// validateGenesisParamCircuitCrossRefs checks param integrity both ways:
//   - each VkParam: param_key checksum half == SHA256(param_bytes)
//   - each Circuit: footer/key alignment against embedded params
//   - each Circuit with a 36-byte param half: must have a matching VkParam entry
//     whose ParamKey equals circuit_key[:36] and whose bytes match that key
func validateGenesisParamCircuitCrossRefs(data types.GenesisState) error {
	// Map 36-byte param_key -> genesis VkParam for O(1) reverse lookup.
	byKey := make(map[string]types.VkParam, len(data.VkParams))
	for _, p := range data.VkParams {
		if len(p.ParamKey) != 36 {
			return fmt.Errorf(
				"genesis vk_param id %d: param_key length %d, want 36",
				p.ParamID, len(p.ParamKey),
			)
		}
		if len(p.ParamBytes) == 0 {
			return fmt.Errorf("genesis vk_param id %d: empty param_bytes", p.ParamID)
		}
		sum := sha256.Sum256(p.ParamBytes)
		if !bytes.Equal(sum[:], p.ParamKey[4:36]) {
			return fmt.Errorf(
				"genesis vk_param id %d: param_key checksum %x != SHA256(param_bytes) %x",
				p.ParamID, p.ParamKey[4:36], sum[:],
			)
		}
		if prev, dup := byKey[string(p.ParamKey)]; dup {
			return fmt.Errorf(
				"genesis vk_param id %d: duplicate param_key %x (also param_id %d)",
				p.ParamID, p.ParamKey, prev.ParamID,
			)
		}
		byKey[string(p.ParamKey)] = p
	}

	for _, c := range data.Circuits {
		if err := validateCircuitParamAlignment(c.ZkBytes, c.ZkInfo); err != nil {
			return fmt.Errorf("genesis circuit zk_id %d: %w", c.ZkID, err)
		}

		// Circuits using the 72-byte key layout must declare a matching VkParam.
		// Legacy short CircuitHash (< 36) skips the cross-ref (pre-param-split era).
		if len(c.ZkInfo.CircuitHash) < 36 {
			continue
		}
		paramHalf := c.ZkInfo.CircuitHash[:36]
		vp, ok := byKey[string(paramHalf)]
		if !ok {
			return fmt.Errorf(
				"genesis circuit zk_id %d: circuit_key[:36]=%x has no matching vk_params entry — every circuit param half must be declared in genesis vk_params",
				c.ZkID, paramHalf,
			)
		}
		// Bytes declared for that VkParam must match the slice embedded in the circuit blob.
		if paramBytes, ok := circuitParamBytes(c.ZkBytes, c.ZkInfo); ok {
			if !bytes.Equal(paramBytes, vp.ParamBytes) {
				return fmt.Errorf(
					"genesis circuit zk_id %d: embedded params (%d bytes) != vk_param id %d bytes (%d) for param_key %x",
					c.ZkID, len(paramBytes), vp.ParamID, len(vp.ParamBytes), paramHalf,
				)
			}
		}
	}
	return nil
}

// IterateVkParamInfos walks sequential param IDs that have metadata entries.
func (k Keeper) IterateVkParamInfos(ctx context.Context, cb func(uint64, types.VkParamInfoResponse) bool) {
	prefixStore := prefix.NewStore(runtime.KVStoreAdapter(k.storeService.OpenKVStore(ctx)), types.VkParamKeyPrefix)
	iter := prefixStore.Iterator(nil, nil)
	defer iter.Close()
	for ; iter.Valid(); iter.Next() {
		var info types.VkParamInfoResponse
		k.cdc.MustUnmarshal(iter.Value(), &info)
		paramID := binary.BigEndian.Uint64(iter.Key())
		if cb(paramID, info) {
			return
		}
	}
}

func (k Keeper) instantiate(
	ctx context.Context,
	codeID uint64,
	creator, admin sdk.AccAddress,
	initMsg []byte,
	label string,
	deposit sdk.Coins,
	addressGenerator AddressGenerator,
	authPolicy types.AuthorizationPolicy,
) (sdk.AccAddress, []byte, error) {
	defer telemetry.MeasureSince(time.Now(), "wasm", "contract", "instantiate") // nolint:staticcheck // TODO update to OTEL

	if creator == nil {
		return nil, nil, types.ErrEmpty.Wrap("creator")
	}
	sdkCtx := sdk.UnwrapSDKContext(ctx)

	codeInfo := k.GetCodeInfo(ctx, codeID)
	if codeInfo == nil {
		return nil, nil, types.ErrNoSuchCodeFn(codeID).Wrapf("code id %d", codeID)
	}

	sdkCtx, discount := k.checkDiscountEligibility(sdkCtx, codeInfo.CodeHash, k.IsPinnedCode(sdkCtx, codeID))
	setupCost := k.gasRegister.SetupContractCost(discount, len(initMsg))

	sdkCtx.GasMeter().ConsumeGas(setupCost, "Loading CosmWasm module: instantiate")

	if !authPolicy.CanInstantiateContract(codeInfo.InstantiateConfig, creator) {
		return nil, nil, errorsmod.Wrap(sdkerrors.ErrUnauthorized, "can not instantiate")
	}
	contractAddress := addressGenerator(ctx, codeID, codeInfo.CodeHash)
	if k.HasContractInfo(ctx, contractAddress) {
		// This case must only happen for instantiate2 because instantiate is based on a counter in state.
		// So we create an instantiate2 specific error message here even though technically this function
		// is used for both cases.
		return nil, nil, types.ErrDuplicate.Wrap("contract address already exists, try a different combination of creator, checksum and salt")
	}

	// check account
	// every cosmos module can define custom account types when needed. The cosmos-sdk comes with extension points
	// to support this and a set of base and vesting account types that we integrated in our default lists.
	// But not all account types of other modules are known or may make sense for contracts, therefore we kept this
	// decision logic also very flexible and extendable. We provide new options to overwrite the default settings via WithAcceptedAccountTypesOnContractInstantiation and
	// WithPruneAccountTypesOnContractInstantiation as constructor arguments
	existingAcct := k.accountKeeper.GetAccount(sdkCtx, contractAddress)
	if existingAcct != nil {
		if existingAcct.GetSequence() != 0 || existingAcct.GetPubKey() != nil {
			return nil, nil, types.ErrAccountExists.Wrap("address is claimed by external account")
		}
		if _, accept := k.acceptedAccountTypes[reflect.TypeOf(existingAcct)]; accept {
			// keep account and balance as it is
			k.Logger(sdkCtx).Info("instantiate contract with existing account", "address", contractAddress.String())
		} else {
			// consider an account in the wasmd namespace spam and overwrite it.
			k.Logger(sdkCtx).Info("pruning existing account for contract instantiation", "address", contractAddress.String())
			contractAccount := k.accountKeeper.NewAccountWithAddress(sdkCtx, contractAddress)
			k.accountKeeper.SetAccount(sdkCtx, contractAccount)
			// also handle balance to not open cases where these accounts are abused and become liquid
			switch handled, err := k.accountPruner.CleanupExistingAccount(sdkCtx, existingAcct); {
			case err != nil:
				return nil, nil, errorsmod.Wrap(err, "prune balance")
			case !handled:
				return nil, nil, types.ErrAccountExists.Wrap("address is claimed by external account")
			}
		}
	} else {
		// create an empty account (so we don't have issues later)
		contractAccount := k.accountKeeper.NewAccountWithAddress(sdkCtx, contractAddress)
		k.accountKeeper.SetAccount(sdkCtx, contractAccount)
	}
	// deposit initial contract funds
	if !deposit.IsZero() {
		if err := k.bank.TransferCoins(sdkCtx, creator, contractAddress, deposit); err != nil {
			return nil, nil, err
		}
	}

	// prepare params for contract instantiate call
	env := types.NewEnv(sdkCtx, k.txHash, contractAddress)
	info := types.NewInfo(creator, deposit)

	// create prefixed data store
	// 0x03 | BuildContractAddressClassic (sdk.AccAddress)
	prefixStoreKey := types.GetContractStorePrefix(contractAddress)
	vmStore := types.NewStoreAdapter(prefix.NewStore(runtime.KVStoreAdapter(k.storeService.OpenKVStore(sdkCtx)), prefixStoreKey))

	// prepare querier
	querier := k.newQueryHandler(sdkCtx, contractAddress)

	// instantiate wasm contract
	gasLeft := k.runtimeGasForContract(sdkCtx)
	res, gasUsed, err := k.wasmVM.Instantiate(codeInfo.CodeHash, env, info, initMsg, vmStore, cosmwasmAPI, querier, k.gasMeter(sdkCtx), gasLeft, costJSONDeserialization)
	k.consumeRuntimeGas(sdkCtx, gasUsed)
	if err != nil {
		return nil, nil, errorsmod.Wrap(types.ErrVMError, err.Error())
	}
	if res == nil {
		// If this gets executed, that's a bug in wasmvm
		return nil, nil, errorsmod.Wrap(types.ErrVMError, "internal wasmvm error")
	}
	if res.Err != "" {
		return nil, nil, types.MarkErrorDeterministic(errorsmod.Wrap(types.ErrInstantiateFailed, res.Err))
	}
	if res.Ok == nil {
		// If this gets executed, that's a bug in wasmvm or a malformed contract result
		return nil, nil, errorsmod.Wrap(types.ErrVMError, "internal wasmvm error: nil ok response")
	}

	// persist instance first
	createdAt := types.NewAbsoluteTxPosition(sdkCtx)
	contractInfo := types.NewContractInfo(codeID, creator, admin, label, createdAt)

	// check for IBC flag
	report, err := k.wasmVM.AnalyzeCode(codeInfo.CodeHash)
	if err != nil {
		return nil, nil, errorsmod.Wrap(types.ErrVMError, err.Error())
	}
	if report.HasIBCEntryPoints {
		// register IBC port
		ibcPort := PortIDForContract(contractAddress)
		contractInfo.IBCPortID = ibcPort
	}

	contractInfo.IBC2PortID = PortIDForContractV2(contractAddress)

	// store contract before dispatch so that contract could be called back
	historyEntry := contractInfo.InitialHistory(initMsg)
	err = k.addToContractCodeSecondaryIndex(sdkCtx, contractAddress, historyEntry)
	if err != nil {
		return nil, nil, err
	}
	err = k.addToContractCreatorSecondaryIndex(sdkCtx, creator, historyEntry.Updated, contractAddress)
	if err != nil {
		return nil, nil, err
	}
	err = k.appendToContractHistory(sdkCtx, contractAddress, historyEntry)
	if err != nil {
		return nil, nil, err
	}

	k.mustStoreContractInfo(sdkCtx, contractAddress, &contractInfo)

	sdkCtx.EventManager().EmitEvent(sdk.NewEvent(
		types.EventTypeInstantiate,
		sdk.NewAttribute(types.AttributeKeyContractAddr, contractAddress.String()),
		sdk.NewAttribute(types.AttributeKeyCodeID, strconv.FormatUint(codeID, 10)),
	))

	sdkCtx = types.WithSubMsgAuthzPolicy(sdkCtx, authPolicy.SubMessageAuthorizationPolicy(types.AuthZActionInstantiate))
	data, err := k.handleContractResponse(sdkCtx, contractAddress, contractInfo.IBCPortID, res.Ok.Messages, res.Ok.Attributes, res.Ok.Data, res.Ok.Events)
	if err != nil {
		return nil, nil, errorsmod.Wrap(err, "dispatch")
	}

	return contractAddress, data, nil
}

// Execute executes the contract instance
func (k Keeper) execute(ctx context.Context, contractAddress, caller sdk.AccAddress, msg []byte, coins sdk.Coins) ([]byte, error) {
	defer telemetry.MeasureSince(time.Now(), "wasm", "contract", "execute") // nolint:staticcheck // TODO update to OTEL
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	contractInfo, codeInfo, prefixStore, err := k.contractInstance(ctx, contractAddress)
	if err != nil {
		return nil, err
	}

	sdkCtx, discount := k.checkDiscountEligibility(sdkCtx, codeInfo.CodeHash, k.IsPinnedCode(ctx, contractInfo.CodeID))
	setupCost := k.gasRegister.SetupContractCost(discount, len(msg))

	sdkCtx.GasMeter().ConsumeGas(setupCost, "Loading CosmWasm module: execute")

	// add more funds
	if !coins.IsZero() {
		if err := k.bank.TransferCoins(sdkCtx, caller, contractAddress, coins); err != nil {
			return nil, err
		}
	}

	env := types.NewEnv(sdkCtx, k.txHash, contractAddress)
	info := types.NewInfo(caller, coins)

	// prepare querier
	querier := k.newQueryHandler(sdkCtx, contractAddress)
	gasLeft := k.runtimeGasForContract(sdkCtx)
	res, gasUsed, execErr := k.wasmVM.Execute(codeInfo.CodeHash, env, info, msg, prefixStore, cosmwasmAPI, querier, k.gasMeter(sdkCtx), gasLeft, costJSONDeserialization)
	k.consumeRuntimeGas(sdkCtx, gasUsed)
	if execErr != nil {
		return nil, errorsmod.Wrap(types.ErrVMError, execErr.Error())
	}
	if res == nil {
		// If this gets executed, that's a bug in wasmvm
		return nil, errorsmod.Wrap(types.ErrVMError, "internal wasmvm error")
	}
	if res.Err != "" {
		return nil, types.MarkErrorDeterministic(errorsmod.Wrap(types.ErrExecuteFailed, res.Err))
	}
	if res.Ok == nil {
		// If this gets executed, that's a bug in wasmvm or a malformed contract result
		return nil, errorsmod.Wrap(types.ErrVMError, "internal wasmvm error: nil ok response")
	}

	sdkCtx.EventManager().EmitEvent(sdk.NewEvent(
		types.EventTypeExecute,
		sdk.NewAttribute(types.AttributeKeyContractAddr, contractAddress.String()),
	))

	data, err := k.handleContractResponse(sdkCtx, contractAddress, contractInfo.IBCPortID, res.Ok.Messages, res.Ok.Attributes, res.Ok.Data, res.Ok.Events)
	if err != nil {
		return nil, err
	}

	return data, nil
}

func (k Keeper) migrate(
	ctx context.Context,
	contractAddress sdk.AccAddress,
	caller sdk.AccAddress,
	newCodeID uint64,
	msg []byte,
	authZ types.AuthorizationPolicy,
) ([]byte, error) {
	defer telemetry.MeasureSince(time.Now(), "wasm", "contract", "migrate") // nolint:staticcheck // TODO update to OTEL

	sdkCtx := sdk.UnwrapSDKContext(ctx)

	contractInfo := k.GetContractInfo(ctx, contractAddress)
	if contractInfo == nil {
		return nil, errorsmod.Wrap(sdkerrors.ErrInvalidRequest, "unknown contract")
	}
	if !authZ.CanModifyContract(contractInfo.AdminAddr(), caller) {
		return nil, errorsmod.Wrap(sdkerrors.ErrUnauthorized, "can not migrate")
	}

	newCodeInfo := k.GetCodeInfo(ctx, newCodeID)
	if newCodeInfo == nil {
		return nil, errorsmod.Wrap(sdkerrors.ErrInvalidRequest, "unknown code")
	}

	if !authZ.CanInstantiateContract(newCodeInfo.InstantiateConfig, caller) {
		return nil, errorsmod.Wrap(sdkerrors.ErrUnauthorized, "to use new code")
	}

	// check for IBC flag
	report, err := k.wasmVM.AnalyzeCode(newCodeInfo.CodeHash)
	switch {
	case err != nil:
		return nil, errorsmod.Wrap(types.ErrVMError, err.Error())
	case !report.HasIBCEntryPoints && contractInfo.IBCPortID != "":
		// prevent update to non ibc contract
		return nil, errorsmod.Wrap(types.ErrMigrationFailed, "requires ibc callbacks")
	case report.HasIBCEntryPoints && contractInfo.IBCPortID == "":
		// add ibc port
		ibcPort := PortIDForContract(contractAddress)
		contractInfo.IBCPortID = ibcPort
	}

	ibc2Port := PortIDForContractV2(contractAddress)
	contractInfo.IBC2PortID = ibc2Port

	var response *wasmvmtypes.Response

	// check for migrate version
	oldCodeInfo := k.GetCodeInfo(ctx, contractInfo.CodeID)
	oldReport, err := k.wasmVM.AnalyzeCode(oldCodeInfo.CodeHash)
	if err != nil {
		return nil, errorsmod.Wrap(types.ErrVMError, err.Error())
	}

	// call migrate entrypoint, except if both migrate versions are set and the same value
	if report.ContractMigrateVersion == nil ||
		oldReport.ContractMigrateVersion == nil ||
		*report.ContractMigrateVersion != *oldReport.ContractMigrateVersion {
		response, err = k.callMigrateEntrypoint(sdkCtx, contractAddress, wasmvmtypes.Checksum(newCodeInfo.CodeHash), msg, newCodeID, caller, oldReport.ContractMigrateVersion)
		if err != nil {
			return nil, err
		}
	}

	// delete old secondary index entry
	err = k.removeFromContractCodeSecondaryIndex(ctx, contractAddress, k.mustGetLastContractHistoryEntry(sdkCtx, contractAddress))
	if err != nil {
		return nil, err
	}
	// persist migration updates
	historyEntry := contractInfo.AddMigration(sdkCtx, newCodeID, msg)
	err = k.appendToContractHistory(ctx, contractAddress, historyEntry)
	if err != nil {
		return nil, err
	}
	err = k.addToContractCodeSecondaryIndex(ctx, contractAddress, historyEntry)
	if err != nil {
		return nil, err
	}
	k.mustStoreContractInfo(ctx, contractAddress, contractInfo)

	contractInfo.IBC2PortID = PortIDForContractV2(contractAddress)

	sdkCtx.EventManager().EmitEvent(sdk.NewEvent(
		types.EventTypeMigrate,
		sdk.NewAttribute(types.AttributeKeyCodeID, strconv.FormatUint(newCodeID, 10)),
		sdk.NewAttribute(types.AttributeKeyContractAddr, contractAddress.String()),
	))

	var data []byte

	// if migrate entry point was called
	if response != nil {
		sdkCtx = types.WithSubMsgAuthzPolicy(sdkCtx, authZ.SubMessageAuthorizationPolicy(types.AuthZActionMigrateContract))
		data, err = k.handleContractResponse(
			sdkCtx,
			contractAddress,
			contractInfo.IBCPortID,
			response.Messages,
			response.Attributes,
			response.Data,
			response.Events,
		)
		if err != nil {
			return nil, errorsmod.Wrap(err, "dispatch")
		}
		return data, nil
	}

	return data, nil
}

func (k Keeper) callMigrateEntrypoint(
	sdkCtx sdk.Context,
	contractAddress sdk.AccAddress,
	newChecksum wasmvmtypes.Checksum,
	msg []byte,
	newCodeID uint64,
	senderAddress sdk.AccAddress,
	oldMigrateVersion *uint64,
) (*wasmvmtypes.Response, error) {
	sdkCtx, discount := k.checkDiscountEligibility(sdkCtx, newChecksum, k.IsPinnedCode(sdkCtx, newCodeID))
	setupCost := k.gasRegister.SetupContractCost(discount, len(msg))
	sdkCtx.GasMeter().ConsumeGas(setupCost, "Loading CosmWasm module: migrate")

	env := types.NewEnv(sdkCtx, k.txHash, contractAddress)

	// prepare querier
	querier := k.newQueryHandler(sdkCtx, contractAddress)

	prefixStoreKey := types.GetContractStorePrefix(contractAddress)
	vmStore := types.NewStoreAdapter(prefix.NewStore(runtime.KVStoreAdapter(k.storeService.OpenKVStore(sdkCtx)), prefixStoreKey))
	gasLeft := k.runtimeGasForContract(sdkCtx)

	migrateInfo := wasmvmtypes.MigrateInfo{
		Sender:            senderAddress.String(),
		OldMigrateVersion: oldMigrateVersion,
	}
	res, gasUsed, err := k.wasmVM.MigrateWithInfo(newChecksum, env, msg, migrateInfo, vmStore, cosmwasmAPI, &querier, k.gasMeter(sdkCtx), gasLeft, costJSONDeserialization)

	k.consumeRuntimeGas(sdkCtx, gasUsed)
	if err != nil {
		return nil, errorsmod.Wrap(types.ErrVMError, err.Error())
	}
	if res == nil {
		// If this gets executed, that's a bug in wasmvm
		return nil, errorsmod.Wrap(types.ErrVMError, "internal wasmvm error")
	}
	if res.Err != "" {
		return nil, types.MarkErrorDeterministic(errorsmod.Wrap(types.ErrMigrationFailed, res.Err))
	}
	if res.Ok == nil {
		// If this gets executed, that's a bug in wasmvm or a malformed contract result
		return nil, errorsmod.Wrap(types.ErrVMError, "internal wasmvm error: nil ok response")
	}
	return res.Ok, nil
}

// Sudo allows privileged access to a contract. This can never be called by an external tx, but only by
// another native Go module directly, or on-chain governance (if sudo proposals are enabled). Thus, the keeper doesn't
// place any access controls on it, that is the responsibility or the app developer (who passes the wasm.Keeper in app.go)
//
// Sub-messages returned from the sudo call to the contract are executed with the default authorization policy. This can be
// customized though by passing a new policy with the context. See types.WithSubMsgAuthzPolicy.
// The policy will be read in msgServer.selectAuthorizationPolicy and used for sub-message executions.
// This is an extension point for some very advanced scenarios only. Use with care!
func (k Keeper) Sudo(ctx context.Context, contractAddress sdk.AccAddress, msg []byte) ([]byte, error) {
	defer telemetry.MeasureSince(time.Now(), "wasm", "contract", "sudo") // nolint:staticcheck // TODO update to OTEL

	contractInfo, codeInfo, prefixStore, err := k.contractInstance(ctx, contractAddress)
	if err != nil {
		return nil, err
	}
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	sdkCtx, discount := k.checkDiscountEligibility(sdkCtx, codeInfo.CodeHash, k.IsPinnedCode(ctx, contractInfo.CodeID))
	setupCost := k.gasRegister.SetupContractCost(discount, len(msg))

	sdkCtx.GasMeter().ConsumeGas(setupCost, "Loading CosmWasm module: sudo")

	env := types.NewEnv(sdkCtx, k.txHash, contractAddress)

	// prepare querier
	querier := k.newQueryHandler(sdkCtx, contractAddress)
	gasLeft := k.runtimeGasForContract(sdkCtx)
	res, gasUsed, execErr := k.wasmVM.Sudo(codeInfo.CodeHash, env, msg, prefixStore, cosmwasmAPI, querier, k.gasMeter(sdkCtx), gasLeft, costJSONDeserialization)
	k.consumeRuntimeGas(sdkCtx, gasUsed)
	if execErr != nil {
		return nil, errorsmod.Wrap(types.ErrVMError, execErr.Error())
	}
	if res == nil {
		// If this gets executed, that's a bug in wasmvm
		return nil, errorsmod.Wrap(types.ErrVMError, "internal wasmvm error")
	}
	if res.Err != "" {
		return nil, types.MarkErrorDeterministic(errorsmod.Wrap(types.ErrExecuteFailed, res.Err))
	}
	if res.Ok == nil {
		// If this gets executed, that's a bug in wasmvm or a malformed contract result
		return nil, errorsmod.Wrap(types.ErrVMError, "internal wasmvm error: nil ok response")
	}

	sdkCtx.EventManager().EmitEvent(sdk.NewEvent(
		types.EventTypeSudo,
		sdk.NewAttribute(types.AttributeKeyContractAddr, contractAddress.String()),
	))

	// sudo submessages are executed with the default authorization policy
	data, err := k.handleContractResponse(sdkCtx, contractAddress, contractInfo.IBCPortID, res.Ok.Messages, res.Ok.Attributes, res.Ok.Data, res.Ok.Events)
	if err != nil {
		return nil, errorsmod.Wrap(err, "dispatch")
	}

	return data, nil
}

// reply is only called from keeper internal functions (dispatchSubmessages) after processing the submessage
func (k Keeper) reply(ctx sdk.Context, contractAddress sdk.AccAddress, reply wasmvmtypes.Reply) ([]byte, error) {
	contractInfo, codeInfo, prefixStore, err := k.contractInstance(ctx, contractAddress)
	if err != nil {
		return nil, err
	}

	replyCosts := k.gasRegister.ReplyCosts(true, reply)
	ctx.GasMeter().ConsumeGas(replyCosts, "Loading CosmWasm module: reply")

	env := types.NewEnv(ctx, k.txHash, contractAddress)

	// prepare querier
	querier := k.newQueryHandler(ctx, contractAddress)
	gasLeft := k.runtimeGasForContract(ctx)

	res, gasUsed, execErr := k.wasmVM.Reply(codeInfo.CodeHash, env, reply, prefixStore, cosmwasmAPI, querier, k.gasMeter(ctx), gasLeft, costJSONDeserialization)
	k.consumeRuntimeGas(ctx, gasUsed)
	if execErr != nil {
		return nil, errorsmod.Wrap(types.ErrVMError, execErr.Error())
	}
	if res == nil {
		// If this gets executed, that's a bug in wasmvm
		return nil, errorsmod.Wrap(types.ErrVMError, "internal wasmvm error")
	}
	if res.Err != "" {
		return nil, types.MarkErrorDeterministic(errorsmod.Wrap(types.ErrExecuteFailed, res.Err))
	}
	if res.Ok == nil {
		// If this gets executed, that's a bug in wasmvm or a malformed contract result
		return nil, errorsmod.Wrap(types.ErrVMError, "internal wasmvm error: nil ok response")
	}

	ctx.EventManager().EmitEvent(sdk.NewEvent(
		types.EventTypeReply,
		sdk.NewAttribute(types.AttributeKeyContractAddr, contractAddress.String()),
	))

	data, err := k.handleContractResponse(ctx, contractAddress, contractInfo.IBCPortID, res.Ok.Messages, res.Ok.Attributes, res.Ok.Data, res.Ok.Events)
	if err != nil {
		return nil, errorsmod.Wrap(err, "dispatch")
	}

	return data, nil
}

// addToContractCodeSecondaryIndex adds element to the index for contracts-by-codeid queries
func (k Keeper) addToContractCodeSecondaryIndex(ctx context.Context, contractAddress sdk.AccAddress, entry types.ContractCodeHistoryEntry) error {
	store := k.storeService.OpenKVStore(ctx)
	return store.Set(types.GetContractByCreatedSecondaryIndexKey(contractAddress, entry), []byte{})
}

// removeFromContractCodeSecondaryIndex removes element to the index for contracts-by-codeid queries
func (k Keeper) removeFromContractCodeSecondaryIndex(ctx context.Context, contractAddress sdk.AccAddress, entry types.ContractCodeHistoryEntry) error {
	return k.storeService.OpenKVStore(ctx).Delete(types.GetContractByCreatedSecondaryIndexKey(contractAddress, entry))
}

// addToCircuitCreatorSecondaryIndex adds element to the index for circuits-by-creator queries
func (k Keeper) addToCircuitCreatorSecondaryIndex(ctx context.Context, creatorAddress sdk.AccAddress, position *types.AbsoluteTxPosition, contractAddress sdk.AccAddress) error {
	store := k.storeService.OpenKVStore(ctx)
	return store.Set(types.GetCircuitByCreatorSecondaryIndexKey(creatorAddress, position.Bytes(), contractAddress), []byte{})
}

// addToContractCreatorSecondaryIndex adds element to the index for contracts-by-creator queries
func (k Keeper) addToContractCreatorSecondaryIndex(ctx context.Context, creatorAddress sdk.AccAddress, position *types.AbsoluteTxPosition, contractAddress sdk.AccAddress) error {
	store := k.storeService.OpenKVStore(ctx)
	return store.Set(types.GetContractByCreatorSecondaryIndexKey(creatorAddress, position.Bytes(), contractAddress), []byte{})
}

// IterateContractsByCreator iterates over all contracts with given creator address in order of creation time asc.
func (k Keeper) IterateCircuitsByCreator(ctx context.Context, creator sdk.AccAddress, cb func(address sdk.AccAddress) bool) {
	prefixStore := prefix.NewStore(runtime.KVStoreAdapter(k.storeService.OpenKVStore(ctx)), types.GetCircuitsByCreatorPrefix(creator))
	for iter := prefixStore.Iterator(nil, nil); iter.Valid(); iter.Next() {
		key := iter.Key()
		if cb(key[types.AbsoluteTxPositionLen:]) {
			return
		}
	}
}

// IterateContractsByCreator iterates over all contracts with given creator address in order of creation time asc.
func (k Keeper) IterateContractsByCreator(ctx context.Context, creator sdk.AccAddress, cb func(address sdk.AccAddress) bool) {
	prefixStore := prefix.NewStore(runtime.KVStoreAdapter(k.storeService.OpenKVStore(ctx)), types.GetContractsByCreatorPrefix(creator))
	for iter := prefixStore.Iterator(nil, nil); iter.Valid(); iter.Next() {
		key := iter.Key()
		if cb(key[types.AbsoluteTxPositionLen:]) {
			return
		}
	}
}

// IterateContractsByCode iterates over all contracts with given codeID ASC on code update time.
func (k Keeper) IterateContractsByCode(ctx context.Context, codeID uint64, cb func(address sdk.AccAddress) bool) {
	prefixStore := prefix.NewStore(runtime.KVStoreAdapter(k.storeService.OpenKVStore(ctx)), types.GetContractByCodeIDSecondaryIndexPrefix(codeID))
	iter := prefixStore.Iterator(nil, nil)
	defer iter.Close()

	for ; iter.Valid(); iter.Next() {
		key := iter.Key()
		if cb(key[types.AbsoluteTxPositionLen:]) {
			return
		}
	}
}

func (k Keeper) setContractAdmin(ctx context.Context, contractAddress, caller, newAdmin sdk.AccAddress, authZ types.AuthorizationPolicy) error {
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	contractInfo := k.GetContractInfo(sdkCtx, contractAddress)
	if contractInfo == nil {
		return errorsmod.Wrap(sdkerrors.ErrInvalidRequest, "unknown contract")
	}
	if !authZ.CanModifyContract(contractInfo.AdminAddr(), caller) {
		return errorsmod.Wrap(sdkerrors.ErrUnauthorized, "can not modify contract")
	}
	newAdminStr := newAdmin.String()
	contractInfo.Admin = newAdminStr
	k.mustStoreContractInfo(sdkCtx, contractAddress, contractInfo)
	sdkCtx.EventManager().EmitEvent(sdk.NewEvent(
		types.EventTypeUpdateContractAdmin,
		sdk.NewAttribute(types.AttributeKeyContractAddr, contractAddress.String()),
		sdk.NewAttribute(types.AttributeKeyNewAdmin, newAdminStr),
	))

	return nil
}

func (k Keeper) setContractLabel(ctx context.Context, contractAddress, caller sdk.AccAddress, newLabel string, authZ types.AuthorizationPolicy) error {
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	contractInfo := k.GetContractInfo(sdkCtx, contractAddress)
	if contractInfo == nil {
		return errorsmod.Wrap(sdkerrors.ErrInvalidRequest, "unknown contract")
	}
	if !authZ.CanModifyContract(contractInfo.AdminAddr(), caller) {
		return errorsmod.Wrap(sdkerrors.ErrUnauthorized, "can not modify contract")
	}
	contractInfo.Label = newLabel
	k.mustStoreContractInfo(sdkCtx, contractAddress, contractInfo)
	sdkCtx.EventManager().EmitEvent(sdk.NewEvent(
		types.EventTypeUpdateContractLabel,
		sdk.NewAttribute(types.AttributeKeyContractAddr, contractAddress.String()),
		sdk.NewAttribute(types.AttributeKeyNewLabel, newLabel),
	))

	return nil
}

func (k Keeper) appendToContractHistory(ctx context.Context, contractAddr sdk.AccAddress, newEntries ...types.ContractCodeHistoryEntry) error {
	store := k.storeService.OpenKVStore(ctx)
	// find last element position
	var pos uint64
	prefixStore := prefix.NewStore(runtime.KVStoreAdapter(store), types.GetContractCodeHistoryElementPrefix(contractAddr))
	iter := prefixStore.ReverseIterator(nil, nil)
	defer iter.Close()

	for ; iter.Valid(); iter.Next() {
		if len(iter.Key()) == 8 { // add extra safety in a mixed contract length environment
			pos = sdk.BigEndianToUint64(iter.Key())
			break
		}
	}
	// then store with incrementing position
	for _, e := range newEntries {
		pos++
		key := types.GetContractCodeHistoryElementKey(contractAddr, pos)
		if err := store.Set(key, k.cdc.MustMarshal(&e)); err != nil {
			return err
		}
	}
	return nil
}

func (k Keeper) GetContractHistory(ctx context.Context, contractAddr sdk.AccAddress) []types.ContractCodeHistoryEntry {
	prefixStore := prefix.NewStore(runtime.KVStoreAdapter(k.storeService.OpenKVStore(ctx)), types.GetContractCodeHistoryElementPrefix(contractAddr))
	r := make([]types.ContractCodeHistoryEntry, 0)
	iter := prefixStore.Iterator(nil, nil)
	defer iter.Close()

	for ; iter.Valid(); iter.Next() {
		if len(iter.Key()) != 8 { // add extra safety in a mixed contract length environment
			continue
		}

		var e types.ContractCodeHistoryEntry
		k.cdc.MustUnmarshal(iter.Value(), &e)
		r = append(r, e)
	}
	return r
}

// mustGetLastContractHistoryEntry returns the last element from history. To be used internally only as it panics when none exists
func (k Keeper) mustGetLastContractHistoryEntry(ctx context.Context, contractAddr sdk.AccAddress) types.ContractCodeHistoryEntry {
	prefixStore := prefix.NewStore(runtime.KVStoreAdapter(k.storeService.OpenKVStore(ctx)), types.GetContractCodeHistoryElementPrefix(contractAddr))
	iter := prefixStore.ReverseIterator(nil, nil)
	defer iter.Close()

	var r types.ContractCodeHistoryEntry
	for ; iter.Valid(); iter.Next() {
		if len(iter.Key()) == 8 { // add extra safety in a mixed contract length environment
			k.cdc.MustUnmarshal(iter.Value(), &r)
			return r
		}
	}
	// all contracts have a history
	panic(fmt.Sprintf("no history for %s", contractAddr.String()))
}

// QuerySmart queries the smart contract itself.
func (k Keeper) QuerySmart(ctx context.Context, contractAddr sdk.AccAddress, req []byte) ([]byte, error) {
	defer telemetry.MeasureSince(time.Now(), "wasm", "contract", "query-smart") // nolint:staticcheck // TODO update to OTEL

	// checks and increase query stack size
	sdkCtx, err := checkAndIncreaseQueryStackSize(sdk.UnwrapSDKContext(ctx), k.maxQueryStackSize)
	if err != nil {
		return nil, err
	}

	contractInfo, codeInfo, prefixStore, err := k.contractInstance(sdkCtx, contractAddr)
	if err != nil {
		return nil, err
	}

	sdkCtx, discount := k.checkDiscountEligibility(sdkCtx, codeInfo.CodeHash, k.IsPinnedCode(ctx, contractInfo.CodeID))
	setupCost := k.gasRegister.SetupContractCost(discount, len(req))
	sdkCtx.GasMeter().ConsumeGas(setupCost, "Loading CosmWasm module: query")

	// prepare querier
	querier := k.newQueryHandler(sdkCtx, contractAddr)

	env := types.NewEnv(sdkCtx, k.txHash, contractAddr)
	queryResult, gasUsed, qErr := k.wasmVM.Query(codeInfo.CodeHash, env, req, prefixStore, cosmwasmAPI, querier, k.gasMeter(sdkCtx), k.runtimeGasForContract(sdkCtx), costJSONDeserialization)
	k.consumeRuntimeGas(sdkCtx, gasUsed)
	if qErr != nil {
		return nil, errorsmod.Wrap(types.ErrVMError, qErr.Error())
	}
	if queryResult.Err != "" {
		return nil, types.MarkErrorDeterministic(errorsmod.Wrap(types.ErrQueryFailed, queryResult.Err))
	}
	return queryResult.Ok, nil
}

func checkAndIncreaseQueryStackSize(ctx context.Context, maxQueryStackSize uint32) (sdk.Context, error) {
	var queryStackSize uint32 = 0
	if size, ok := types.QueryStackSize(ctx); ok {
		queryStackSize = size
	}

	// increase
	queryStackSize++

	// did we go too far?
	if queryStackSize > maxQueryStackSize {
		return sdk.Context{}, types.ErrExceedMaxQueryStackSize
	}

	// set updated stack size
	return types.WithQueryStackSize(sdk.UnwrapSDKContext(ctx), queryStackSize), nil
}

func checkAndIncreaseCallDepth(ctx context.Context, maxCallDepth uint32) (sdk.Context, error) {
	var callDepth uint32 = 0
	if size, ok := types.CallDepth(ctx); ok {
		callDepth = size
	}

	// increase
	callDepth++

	// did we go too far?
	if callDepth > maxCallDepth {
		return sdk.Context{}, types.ErrExceedMaxCallDepth
	}

	// set updated stack size
	return types.WithCallDepth(sdk.UnwrapSDKContext(ctx), callDepth), nil
}

// QueryRaw returns the contract's state for give key. Returns `nil` when key is `nil`.
func (k Keeper) QueryRaw(ctx context.Context, contractAddress sdk.AccAddress, key []byte) []byte {
	defer telemetry.MeasureSince(time.Now(), "wasm", "contract", "query-raw") // nolint:staticcheck // TODO update to OTEL
	if key == nil {
		return nil
	}
	prefixStoreKey := types.GetContractStorePrefix(contractAddress)
	prefixStore := prefix.NewStore(runtime.KVStoreAdapter(k.storeService.OpenKVStore(ctx)), prefixStoreKey)
	return prefixStore.Get(key)
}

func (k Keeper) QueryRawRange(ctx context.Context, contractAddress sdk.AccAddress, start, end []byte, limit uint16, reverse bool) (results []wasmvmtypes.RawRangeEntry, nextKey []byte) {
	defer telemetry.MeasureSince(time.Now(), "wasm", "contract", "query-raw-range") // nolint:staticcheck // TODO update to OTEL

	prefixStoreKey := types.GetContractStorePrefix(contractAddress)
	prefixStore := prefix.NewStore(runtime.KVStoreAdapter(k.storeService.OpenKVStore(ctx)), prefixStoreKey)
	var iter storetypes.Iterator
	if reverse {
		iter = prefixStore.ReverseIterator(start, end)
	} else {
		iter = prefixStore.Iterator(start, end)
	}
	defer iter.Close()

	// Make sure to set to empty array because the contract doesn't expect a null JSON value
	results = []wasmvmtypes.RawRangeEntry{}

	var count uint16 = 0
	for ; iter.Valid(); iter.Next() {
		// keep track of count to honor the limit
		if count == limit {
			break
		}
		count++

		// add key-value pair
		results = append(results, wasmvmtypes.RawRangeEntry{Key: iter.Key(), Value: iter.Value()})
	}

	if iter.Valid() {
		// if there are more results, set the next key
		key := iter.Key()
		nextKey = key
	} else {
		nextKey = nil
	}

	return results, nextKey
}

// internal helper function
func (k Keeper) circuitVkInstance(ctx context.Context, contractAddress sdk.AccAddress) (types.ContractInfo, types.CodeInfo, wasmvm.KVStore, error) {
	store := k.storeService.OpenKVStore(ctx)

	contractBz, err := store.Get(types.GetContractAddressKey(contractAddress))
	if err != nil {
		return types.ContractInfo{}, types.CodeInfo{}, nil, err
	}
	if contractBz == nil {
		return types.ContractInfo{}, types.CodeInfo{}, nil, types.ErrNoSuchContractFn(contractAddress.String()).
			Wrapf("address %s", contractAddress.String())
	}
	var contractInfo types.ContractInfo
	k.cdc.MustUnmarshal(contractBz, &contractInfo)

	codeInfoBz, err := store.Get(types.GetCodeKey(contractInfo.CodeID))
	if err != nil {
		return types.ContractInfo{}, types.CodeInfo{}, nil, err
	}

	if codeInfoBz == nil {
		return contractInfo, types.CodeInfo{}, nil, types.ErrNoSuchCodeFn(contractInfo.CodeID).
			Wrapf("code id %d", contractInfo.CodeID)
	}
	var codeInfo types.CodeInfo
	k.cdc.MustUnmarshal(codeInfoBz, &codeInfo)
	prefixStoreKey := types.GetContractStorePrefix(contractAddress)
	prefixStore := prefix.NewStore(runtime.KVStoreAdapter(k.storeService.OpenKVStore(ctx)), prefixStoreKey)
	return contractInfo, codeInfo, types.NewStoreAdapter(prefixStore), nil
}

// internal helper function
func (k Keeper) contractInstance(ctx context.Context, contractAddress sdk.AccAddress) (types.ContractInfo, types.CodeInfo, wasmvm.KVStore, error) {
	store := k.storeService.OpenKVStore(ctx)

	contractBz, err := store.Get(types.GetContractAddressKey(contractAddress))
	if err != nil {
		return types.ContractInfo{}, types.CodeInfo{}, nil, err
	}
	if contractBz == nil {
		return types.ContractInfo{}, types.CodeInfo{}, nil, types.ErrNoSuchContractFn(contractAddress.String()).
			Wrapf("address %s", contractAddress.String())
	}
	var contractInfo types.ContractInfo
	k.cdc.MustUnmarshal(contractBz, &contractInfo)

	codeInfoBz, err := store.Get(types.GetCodeKey(contractInfo.CodeID))
	if err != nil {
		return types.ContractInfo{}, types.CodeInfo{}, nil, err
	}

	if codeInfoBz == nil {
		return contractInfo, types.CodeInfo{}, nil, types.ErrNoSuchCodeFn(contractInfo.CodeID).
			Wrapf("code id %d", contractInfo.CodeID)
	}
	var codeInfo types.CodeInfo
	k.cdc.MustUnmarshal(codeInfoBz, &codeInfo)
	prefixStoreKey := types.GetContractStorePrefix(contractAddress)
	prefixStore := prefix.NewStore(runtime.KVStoreAdapter(k.storeService.OpenKVStore(ctx)), prefixStoreKey)
	return contractInfo, codeInfo, types.NewStoreAdapter(prefixStore), nil
}

func (k Keeper) LoadAsyncAckPacket(ctx context.Context, portID, channelID string, sequence uint64) (channeltypes.Packet, error) {
	prefixStore, key := k.getAsyncAckStoreAndKey(ctx, portID, channelID, sequence)

	packetBz := prefixStore.Get(key)

	if len(packetBz) == 0 {
		return channeltypes.Packet{}, types.ErrNotFound.Wrap("packet")
	}

	var packet channeltypes.Packet
	// unmarshal packet
	if err := k.cdc.Unmarshal(packetBz, &packet); err != nil {
		return channeltypes.Packet{}, err
	}

	return packet, nil
}

func (k Keeper) StoreAsyncAckPacket(ctx context.Context, packet channeltypes.Packet) error {
	prefixStore, key := k.getAsyncAckStoreAndKey(ctx, packet.DestinationPort, packet.DestinationChannel, packet.Sequence)

	packetBz, err := k.cdc.Marshal(&packet)
	if err != nil {
		return err
	}
	prefixStore.Set(key, packetBz)
	return nil
}

func (k Keeper) DeleteAsyncAckPacket(ctx context.Context, portID, channelID string, sequence uint64) {
	prefixStore, key := k.getAsyncAckStoreAndKey(ctx, portID, channelID, sequence)
	prefixStore.Delete(key)
}

func (k Keeper) getAsyncAckStoreAndKey(ctx context.Context, portID, channelID string, sequence uint64) (prefix.Store, []byte) {
	// packets are stored under the destination port
	prefixStoreKey := types.GetAsyncAckStorePrefix(portID)
	prefixStore := prefix.NewStore(runtime.KVStoreAdapter(k.storeService.OpenKVStore(ctx)), prefixStoreKey)
	key := types.GetAsyncPacketKey(channelID, sequence)
	return prefixStore, key
}

func (k Keeper) GetContractInfo(ctx context.Context, contractAddress sdk.AccAddress) *types.ContractInfo {
	store := k.storeService.OpenKVStore(ctx)
	var contract types.ContractInfo
	contractBz, err := store.Get(types.GetContractAddressKey(contractAddress))
	if err != nil {
		panic(err)
	}
	if contractBz == nil {
		return nil
	}
	k.cdc.MustUnmarshal(contractBz, &contract)
	return &contract
}

func (k Keeper) HasContractInfo(ctx context.Context, contractAddress sdk.AccAddress) bool {
	store := k.storeService.OpenKVStore(ctx)
	ok, err := store.Has(types.GetContractAddressKey(contractAddress))
	if err != nil {
		panic(err)
	}
	return ok
}

// mustStoreContractInfo persists the ContractInfo. No secondary index updated here.
func (k Keeper) mustStoreContractInfo(ctx context.Context, contractAddress sdk.AccAddress, contract *types.ContractInfo) {
	store := k.storeService.OpenKVStore(ctx)
	err := store.Set(types.GetContractAddressKey(contractAddress), k.cdc.MustMarshal(contract))
	if err != nil {
		panic(err)
	}
}

func (k Keeper) IterateContractInfo(ctx context.Context, cb func(sdk.AccAddress, types.ContractInfo) bool) {
	prefixStore := prefix.NewStore(runtime.KVStoreAdapter(k.storeService.OpenKVStore(ctx)), types.ContractKeyPrefix)
	iter := prefixStore.Iterator(nil, nil)
	defer iter.Close()

	for ; iter.Valid(); iter.Next() {
		var contract types.ContractInfo
		k.cdc.MustUnmarshal(iter.Value(), &contract)
		// cb returns true to stop early
		if cb(iter.Key(), contract) {
			break
		}
	}
}

// IterateContractState iterates through all elements of the key value store for the given contract address and passes
// them to the provided callback function. The callback method can return true to abort early.
func (k Keeper) IterateContractState(ctx context.Context, contractAddress sdk.AccAddress, cb func(key, value []byte) bool) {
	prefixStoreKey := types.GetContractStorePrefix(contractAddress)
	prefixStore := prefix.NewStore(runtime.KVStoreAdapter(k.storeService.OpenKVStore(ctx)), prefixStoreKey)
	iter := prefixStore.Iterator(nil, nil)
	defer iter.Close()

	for ; iter.Valid(); iter.Next() {
		if cb(iter.Key(), iter.Value()) {
			break
		}
	}
}

func (k Keeper) importContractState(ctx context.Context, contractAddress sdk.AccAddress, models []types.Model) error {
	prefixStoreKey := types.GetContractStorePrefix(contractAddress)
	prefixStore := prefix.NewStore(runtime.KVStoreAdapter(k.storeService.OpenKVStore(ctx)), prefixStoreKey)
	for _, model := range models {
		if model.Value == nil {
			model.Value = []byte{}
		}
		if prefixStore.Has(model.Key) {
			return errorsmod.Wrapf(types.ErrDuplicate, "duplicate key: %x", model.Key)
		}
		prefixStore.Set(model.Key, model.Value)
	}

	return nil
}

func (k Keeper) GetCodeInfo(ctx context.Context, codeID uint64) *types.CodeInfo {
	store := k.storeService.OpenKVStore(ctx)
	var codeInfo types.CodeInfo
	codeInfoBz, err := store.Get(types.GetCodeKey(codeID))
	if err != nil {
		panic(err)
	}
	if codeInfoBz == nil {
		return nil
	}
	k.cdc.MustUnmarshal(codeInfoBz, &codeInfo)
	return &codeInfo
}

func (k Keeper) GetCircuitInfo(ctx context.Context, zkID uint64) *types.CircuitInfo {
	store := k.storeService.OpenKVStore(ctx)
	var circuitInfo types.CircuitInfo
	zkInfoBz, err := store.Get(types.GetCircuitInfoKey(zkID))
	if err != nil {
		panic(err)
	}
	if zkInfoBz == nil {
		return nil
	}
	k.cdc.MustUnmarshal(zkInfoBz, &circuitInfo)
	return &circuitInfo
}

func (k Keeper) containsCircuitInfo(ctx context.Context, zkID uint64) bool {
	store := k.storeService.OpenKVStore(ctx)
	ok, err := store.Has(types.GetCircuitInfoKey(zkID))
	if err != nil {
		panic(err)
	}
	return ok
}

func (k Keeper) containsCodeInfo(ctx context.Context, codeID uint64) bool {
	store := k.storeService.OpenKVStore(ctx)
	ok, err := store.Has(types.GetCodeKey(codeID))
	if err != nil {
		panic(err)
	}
	return ok
}

func (k Keeper) IterateCircuitInfos(ctx context.Context, cb func(uint64, types.CircuitInfo) bool) {
	prefixStore := prefix.NewStore(runtime.KVStoreAdapter(k.storeService.OpenKVStore(ctx)), types.CircuitKeyPrefix)
	iter := prefixStore.Iterator(nil, nil)
	defer iter.Close()

	for ; iter.Valid(); iter.Next() {
		var c types.CircuitInfo
		k.cdc.MustUnmarshal(iter.Value(), &c)
		// cb returns true to stop early
		if cb(binary.BigEndian.Uint64(iter.Key()), c) {
			return
		}
	}
}

func (k Keeper) IterateCodeInfos(ctx context.Context, cb func(uint64, types.CodeInfo) bool) {
	prefixStore := prefix.NewStore(runtime.KVStoreAdapter(k.storeService.OpenKVStore(ctx)), types.CodeKeyPrefix)
	iter := prefixStore.Iterator(nil, nil)
	defer iter.Close()

	for ; iter.Valid(); iter.Next() {
		var c types.CodeInfo
		k.cdc.MustUnmarshal(iter.Value(), &c)
		// cb returns true to stop early
		if cb(binary.BigEndian.Uint64(iter.Key()), c) {
			return
		}
	}
}

// GetCircuit returns the canonical monolithic circuit blob for zkID.
// Prefers app-state bytes (state sync / genesis / cold path source of truth).
// Falls back to wasmvm disk cache for older nodes that only persisted metadata.
func (k Keeper) GetCircuit(ctx context.Context, zkID uint64) ([]byte, error) {
	store := k.storeService.OpenKVStore(ctx)

	// Canonical chain state — required for cold path and export without recompute.
	if blob, err := store.Get(types.GetCircuitBytesKey(zkID)); err != nil {
		return nil, err
	} else if blob != nil {
		return blob, nil
	}

	// Migration fallback: older stores only had CircuitInfo + wasmvm files.
	var circuitInfo types.CircuitInfo
	zkInfoBz, err := store.Get(types.GetCircuitKey(zkID))
	if err != nil {
		return nil, err
	}
	if zkInfoBz == nil {
		return nil, nil
	}
	k.cdc.MustUnmarshal(zkInfoBz, &circuitInfo)
	blob, err := k.wasmVM.GetCircuit(circuitInfo.CircuitHash)
	if err != nil {
		return nil, err
	}
	// Backfill app state so future queries and exports do not depend on wasmvm alone.
	if blob != nil {
		_ = store.Set(types.GetCircuitBytesKey(zkID), blob)
	}
	return blob, nil
}

func (k Keeper) GetByteCode(ctx context.Context, codeID uint64) ([]byte, error) {
	store := k.storeService.OpenKVStore(ctx)
	var codeInfo types.CodeInfo
	codeInfoBz, err := store.Get(types.GetCodeKey(codeID))
	if err != nil {
		return nil, err
	}
	if codeInfoBz == nil {
		return nil, nil
	}
	k.cdc.MustUnmarshal(codeInfoBz, &codeInfo)
	return k.wasmVM.GetCode(codeInfo.CodeHash)
}

// pinCode pins the wasm contract in wasmvm cache
func (k Keeper) pinCode(ctx context.Context, codeID uint64) error {
	codeInfo := k.GetCodeInfo(ctx, codeID)
	if codeInfo == nil {
		return types.ErrNoSuchCodeFn(codeID).Wrapf("code id %d", codeID)
	}

	sdkCtx := sdk.UnwrapSDKContext(ctx)
	pinCost := k.gasRegister.PinCodeCost()
	sdkCtx.GasMeter().ConsumeGas(pinCost, "Loading CosmWasm module: pin code")

	// Collect all currently pinned checksums
	checksums, err := k.collectPinnedChecksums(ctx, nil)
	if err != nil {
		return err
	}

	// Add the new code to pin
	checksums = append(checksums, codeInfo.CodeHash)

	err = k.wasmVM.SyncPinnedCodes(checksums)
	if err != nil {
		return errorsmod.Wrap(types.ErrSyncPinnedCodesFailed, err.Error())
	}

	kvStore := k.storeService.OpenKVStore(ctx)
	// store 1 byte to not run into `nil` debugging issues
	err = kvStore.Set(types.GetPinnedCodeIndexPrefix(codeID), []byte{1})
	if err != nil {
		return err
	}

	sdk.UnwrapSDKContext(ctx).EventManager().EmitEvent(sdk.NewEvent(
		types.EventTypePinCode,
		sdk.NewAttribute(types.AttributeKeyCodeID, strconv.FormatUint(codeID, 10)),
	))
	return nil
}

// pinCircuit pins the zk circuit in wasmvm cache using bulk sync (mirrors pinCode / SyncPinnedCodes).
func (k Keeper) pinCircuit(ctx context.Context, zkID uint64) error {
	zkInfo := k.GetCircuitInfo(ctx, zkID)
	if zkInfo == nil {
		return types.ErrNoSuchCodeFn(zkID).Wrapf("zk id %d", zkID)
	}

	// Collect all currently pinned circuit keys, then add this one.
	keys, err := k.collectPinnedCircuitKeys(ctx, nil)
	if err != nil {
		return err
	}
	keys = append(keys, zkInfo.CircuitHash)

	if err := k.wasmVM.SyncPinnedCircuits(keys); err != nil {
		return errorsmod.Wrap(types.ErrPinCircuitFailed, err.Error())
	}
	store := k.storeService.OpenKVStore(ctx)
	// store 1 byte to not run into `nil` debugging issues
	err = store.Set(types.GetPinnedCircuitIndexPrefix(zkID), []byte{1})
	if err != nil {
		return err
	}

	sdk.UnwrapSDKContext(ctx).EventManager().EmitEvent(sdk.NewEvent(
		types.EventTypePinCircuit,
		sdk.NewAttribute(types.AttributeKeyZkID, strconv.FormatUint(zkID, 10)),
	))
	return nil
}

// unpinCode removes the wasm contract from wasmvm cache
func (k Keeper) unpinCode(ctx context.Context, codeID uint64) error {
	codeInfo := k.GetCodeInfo(ctx, codeID)
	if codeInfo == nil {
		return types.ErrNoSuchCodeFn(codeID).Wrapf("code id %d", codeID)
	}

	sdkCtx := sdk.UnwrapSDKContext(ctx)
	unpinCost := k.gasRegister.UnpinCodeCost()
	sdkCtx.GasMeter().ConsumeGas(unpinCost, "Loading CosmWasm module: unpin code")

	// Collect all pinned checksums except the one we're unpinning
	checksums, err := k.collectPinnedChecksums(ctx, &codeID)
	if err != nil {
		return err
	}

	err = k.wasmVM.SyncPinnedCodes(checksums)
	if err != nil {
		return errorsmod.Wrap(types.ErrSyncPinnedCodesFailed, err.Error())
	}

	kvStore := k.storeService.OpenKVStore(ctx)
	err = kvStore.Delete(types.GetPinnedCodeIndexPrefix(codeID))
	if err != nil {
		return err
	}

	sdk.UnwrapSDKContext(ctx).EventManager().EmitEvent(sdk.NewEvent(
		types.EventTypeUnpinCode,
		sdk.NewAttribute(types.AttributeKeyCodeID, strconv.FormatUint(codeID, 10)),
	))
	return nil
}

// unpinCircuit removes the zk circuit from wasmvm cache via bulk sync (mirrors unpinCode).
func (k Keeper) unpinCircuit(ctx context.Context, zkID uint64) error {
	zkInfo := k.GetCircuitInfo(ctx, zkID)
	if zkInfo == nil {
		return types.ErrNoSuchCodeFn(zkID).Wrapf("zk-circuit id %d", zkID)
	}

	keys, err := k.collectPinnedCircuitKeys(ctx, &zkID)
	if err != nil {
		return err
	}
	if err := k.wasmVM.SyncPinnedCircuits(keys); err != nil {
		return errorsmod.Wrap(types.ErrUnpinCircuitFailed, err.Error())
	}

	store := k.storeService.OpenKVStore(ctx)
	err = store.Delete(types.GetPinnedCircuitIndexPrefix(zkID))
	if err != nil {
		return err
	}

	sdk.UnwrapSDKContext(ctx).EventManager().EmitEvent(sdk.NewEvent(
		types.EventTypeUnpinCircuit,
		sdk.NewAttribute(types.AttributeKeyZkID, strconv.FormatUint(zkID, 10)),
	))
	return nil
}

// IsPinnedCircuit returns true when zkID is pinned in wasmvm cache
func (k Keeper) IsPinnedCircuit(ctx context.Context, zkID uint64) bool {
	store := k.storeService.OpenKVStore(ctx)
	ok, err := store.Has(types.GetPinnedCircuitIndexPrefix(zkID))
	if err != nil {
		panic(err)
	}
	return ok
}

// collectPinnedChecksums collects checksums for all pinned codes, optionally excluding one
func (k Keeper) collectPinnedChecksums(ctx context.Context, excludeCodeID *uint64) ([]wasmvm.Checksum, error) {
	store := prefix.NewStore(runtime.KVStoreAdapter(k.storeService.OpenKVStore(ctx)), types.PinnedCodeIndexPrefix)
	iter := store.Iterator(nil, nil)
	defer iter.Close()

	checksums := make([]wasmvm.Checksum, 0)
	for ; iter.Valid(); iter.Next() {
		pinnedCodeID := types.ParsePinnedCodeIndex(iter.Key())

		// Skip the excluded code ID if specified
		if excludeCodeID != nil && pinnedCodeID == *excludeCodeID {
			continue
		}

		codeInfo := k.GetCodeInfo(ctx, pinnedCodeID)
		if codeInfo == nil {
			return nil, types.ErrNoSuchCodeFn(pinnedCodeID).Wrapf("code id %d", pinnedCodeID)
		}
		checksums = append(checksums, codeInfo.CodeHash)
	}

	return checksums, nil
}

// collectPinnedCircuitKeys collects CircuitHash keys for all pinned circuits, optionally excluding one zkID.
func (k Keeper) collectPinnedCircuitKeys(ctx context.Context, excludeZkID *uint64) ([]wasmvm.Checksum, error) {
	store := prefix.NewStore(runtime.KVStoreAdapter(k.storeService.OpenKVStore(ctx)), types.PinnedCircuitsIndexPrefix)
	iter := store.Iterator(nil, nil)
	defer iter.Close()

	keys := make([]wasmvm.Checksum, 0)
	for ; iter.Valid(); iter.Next() {
		zkID := types.ParsePinnedCircuitIndex(iter.Key())
		if excludeZkID != nil && zkID == *excludeZkID {
			continue
		}
		info := k.GetCircuitInfo(ctx, zkID)
		if info == nil {
			return nil, types.ErrNoSuchCircuitFn(zkID).Wrapf("zk-circuit id %d", zkID)
		}
		keys = append(keys, info.CircuitHash)
	}
	return keys, nil
}

// IsPinnedCode returns true when codeID is pinned in wasmvm cache
func (k Keeper) IsPinnedCode(ctx context.Context, codeID uint64) bool {
	store := k.storeService.OpenKVStore(ctx)
	ok, err := store.Has(types.GetPinnedCodeIndexPrefix(codeID))
	if err != nil {
		panic(err)
	}
	return ok
}

func (k Keeper) checkDiscountEligibility(ctx sdk.Context, checksum []byte, isPinned bool) (sdk.Context, bool) {
	if isPinned {
		return ctx, true
	}

	txContracts, ok := types.TxContractsFromContext(ctx)
	if !ok || txContracts.GetContracts() == nil {
		return ctx, false
	} else if txContracts.Exists(checksum) {
		return ctx, true
	}

	txContracts.AddContract(checksum)
	return types.WithTxContracts(ctx, txContracts), false
}

// InitalizedPinnedCodesAndCircuits updates wasmvm to pin to cache all contracts and circuits marked as pinned.
// Uses bulk SyncPinnedCodes / SyncPinnedCircuits (upstream pin semantics) for restart-safe rehydrate.
func (k Keeper) InitalizedPinnedCodesAndCircuits(ctx context.Context) error {
	// Codes: one bulk sync (upstream v3.0.x pattern)
	if err := k.InitializePinnedCodes(ctx); err != nil {
		return err
	}

	// Circuits: bulk sync of 72-byte keys
	keys, err := k.collectPinnedCircuitKeys(ctx, nil)
	if err != nil {
		return err
	}
	if len(keys) == 0 {
		return nil
	}
	if err := k.wasmVM.SyncPinnedCircuits(keys); err != nil {
		return errorsmod.Wrap(types.ErrPinCircuitFailed, err.Error())
	}
	return nil
}

// InitializePinnedCodes updates wasmvm to pin to cache all contracts marked as pinned.
// Pinned cache (SyncPinnedCodes) is unbounded: pin <10 hot codeIDs via gov MsgPinCodes
// (HashMerchant callbacks, cw-hooks listeners, CosmWasm authenticators). Pinning 100s OOMs.
// Watch size_pinned_memory_cache via get_pinned_metrics. No EndBlocker / auto-pin.
func (k Keeper) InitializePinnedCodes(ctx context.Context) error {
	store := prefix.NewStore(runtime.KVStoreAdapter(k.storeService.OpenKVStore(ctx)), types.PinnedCodeIndexPrefix)
	iter := store.Iterator(nil, nil)
	defer iter.Close()

	checksums := make([]wasmvm.Checksum, 0)
	for ; iter.Valid(); iter.Next() {
		codeID := types.ParsePinnedCodeIndex(iter.Key())
		codeInfo := k.GetCodeInfo(ctx, codeID)
		if codeInfo == nil {
			return types.ErrNoSuchCodeFn(codeID).Wrapf("code id %d", codeID)
		}
		checksums = append(checksums, codeInfo.CodeHash)
	}

	if len(checksums) == 0 {
		return nil
	}

	if err := k.wasmVM.SyncPinnedCodes(checksums); err != nil {
		return errorsmod.Wrap(types.ErrPinContractFailed, err.Error())
	}
	return nil
}

// setContractInfoExtension updates the extension point data that is stored with the contract info
func (k Keeper) setContractInfoExtension(ctx context.Context, contractAddr sdk.AccAddress, ext types.ContractInfoExtension) error {
	info := k.GetContractInfo(ctx, contractAddr)
	if info == nil {
		return types.ErrNoSuchContractFn(contractAddr.String()).
			Wrapf("address %s", contractAddr.String())
	}
	if err := info.SetExtension(ext); err != nil {
		return err
	}
	k.mustStoreContractInfo(ctx, contractAddr, info)
	return nil
}

// setAccessConfig updates the access config of a code id.
func (k Keeper) setAccessConfig(ctx context.Context, codeID uint64, caller sdk.AccAddress, newConfig types.AccessConfig, authz types.AuthorizationPolicy) error {
	info := k.GetCodeInfo(ctx, codeID)
	if info == nil {
		return types.ErrNoSuchCodeFn(codeID).Wrapf("code id %d", codeID)
	}
	isSubset := newConfig.Permission.IsSubset(k.getInstantiateAccessConfig(ctx))
	if !authz.CanModifyCodeAccessConfig(sdk.MustAccAddressFromBech32(info.Creator), caller, isSubset) {
		return errorsmod.Wrap(sdkerrors.ErrUnauthorized, "can not modify code access config")
	}

	info.InstantiateConfig = newConfig
	k.mustStoreCodeInfo(ctx, codeID, *info)
	evt := sdk.NewEvent(
		types.EventTypeUpdateCodeAccessConfig,
		sdk.NewAttribute(types.AttributeKeyCodePermission, newConfig.Permission.String()),
		sdk.NewAttribute(types.AttributeKeyCodeID, strconv.FormatUint(codeID, 10)),
	)
	if addrs := newConfig.AllAuthorizedAddresses(); len(addrs) != 0 {
		attr := sdk.NewAttribute(types.AttributeKeyAuthorizedAddresses, strings.Join(addrs, ","))
		evt.Attributes = append(evt.Attributes, attr.ToKVPair())
	}
	sdk.UnwrapSDKContext(ctx).EventManager().EmitEvent(evt)
	return nil
}

// handleContractResponse processes the contract response data by emitting events and sending sub-/messages.
func (k *Keeper) handleContractResponse(
	ctx sdk.Context,
	contractAddr sdk.AccAddress,
	ibcPort string,
	msgs []wasmvmtypes.SubMsg,
	attrs []wasmvmtypes.EventAttribute,
	data []byte,
	evts wasmvmtypes.Array[wasmvmtypes.Event],
) ([]byte, error) {
	attributeGasCost := k.gasRegister.EventCosts(attrs, evts)
	ctx.GasMeter().ConsumeGas(attributeGasCost, "Custom contract event attributes")
	// emit all events from this contract itself
	if len(attrs) != 0 {
		wasmEvents, err := newWasmModuleEvent(attrs, contractAddr)
		if err != nil {
			return nil, err
		}
		ctx.EventManager().EmitEvents(wasmEvents)
	}
	if len(evts) > 0 {
		customEvents, err := newCustomEvents(evts, contractAddr)
		if err != nil {
			return nil, err
		}
		ctx.EventManager().EmitEvents(customEvents)
	}
	// keep track of call depth
	ctx, err := checkAndIncreaseCallDepth(ctx, k.maxCallDepth)
	if err != nil {
		return nil, err
	}
	return k.wasmVMResponseHandler.Handle(ctx, contractAddr, ibcPort, msgs, data)
}

func (k Keeper) runtimeGasForContract(ctx sdk.Context) uint64 {
	meter := ctx.GasMeter()
	if meter.IsOutOfGas() {
		return 0
	}
	if meter.Limit() == math.MaxUint64 { // infinite gas meter and not out of gas
		return math.MaxUint64
	}
	return k.gasRegister.ToWasmVMGas(meter.Limit() - meter.GasConsumedToLimit())
}

func (k Keeper) consumeRuntimeGas(ctx sdk.Context, gas uint64) {
	consumed := k.gasRegister.FromWasmVMGas(gas)
	ctx.GasMeter().ConsumeGas(consumed, "wasm contract")
	// throw OutOfGas error if we ran out (got exactly to zero due to better limit enforcing)
	if ctx.GasMeter().IsOutOfGas() {
		panic(storetypes.ErrorOutOfGas{Descriptor: "Wasm engine function execution"})
	}
}

func (k Keeper) mustAutoIncrementID(ctx context.Context, sequenceKey []byte) uint64 {
	store := k.storeService.OpenKVStore(ctx)
	bz, err := store.Get(sequenceKey)
	if err != nil {
		panic(err)
	}
	id := uint64(1)
	if bz != nil {
		id = binary.BigEndian.Uint64(bz)
	}
	bz = sdk.Uint64ToBigEndian(id + 1)
	err = store.Set(sequenceKey, bz)
	if err != nil {
		panic(err)
	}
	return id
}

// mustAutoIncrementIDUint32 auto-increments a u32 sequence counter in storage
// Used for zkID generation (which must fit in u32 for FFI compatibility)
func (k Keeper) mustAutoIncrementIDUint32(ctx context.Context, sequenceKey []byte) uint32 {
	store := k.storeService.OpenKVStore(ctx)
	bz, err := store.Get(sequenceKey)
	if err != nil {
		panic(err)
	}
	id := uint32(1)
	if bz != nil {
		id = binary.LittleEndian.Uint32(bz)
	}
	bz = make([]byte, 4)
	binary.LittleEndian.PutUint32(bz, id+1)
	err = store.Set(sequenceKey, bz)
	if err != nil {
		panic(err)
	}
	return id
}

// PeekAutoIncrementID reads the current value without incrementing it.
func (k Keeper) PeekAutoIncrementIDUint32(ctx context.Context, sequenceKey []byte) (uint32, error) {
	store := k.storeService.OpenKVStore(ctx)
	bz, err := store.Get(sequenceKey)
	if err != nil {
		return 0, errorsmod.Wrap(err, "sequence key")
	}
	id := uint32(1)
	if bz != nil {
		id = binary.LittleEndian.Uint32(bz)
	}
	return id, nil
}

// PeekAutoIncrementID reads the current value without incrementing it.
func (k Keeper) PeekAutoIncrementID(ctx context.Context, sequenceKey []byte) (uint64, error) {
	store := k.storeService.OpenKVStore(ctx)
	bz, err := store.Get(sequenceKey)
	if err != nil {
		return 0, errorsmod.Wrap(err, "sequence key")
	}
	id := uint64(1)
	if bz != nil {
		id = binary.BigEndian.Uint64(bz)
	}
	return id, nil
}

func (k Keeper) importAutoIncrementID(ctx context.Context, sequenceKey []byte, val uint64) error {
	store := k.storeService.OpenKVStore(ctx)
	ok, err := store.Has(sequenceKey)
	if err != nil {
		return errorsmod.Wrap(err, "sequence key")
	}
	if ok {
		return errorsmod.Wrapf(types.ErrDuplicate, "autoincrement id: %s", string(sequenceKey))
	}
	bz := sdk.Uint64ToBigEndian(val)
	return store.Set(sequenceKey, bz)
}

func (k Keeper) importContract(ctx context.Context, contractAddr sdk.AccAddress, c *types.ContractInfo, state []types.Model, historyEntries []types.ContractCodeHistoryEntry) error {
	if !k.containsCodeInfo(ctx, c.CodeID) {
		return types.ErrNoSuchCodeFn(c.CodeID).Wrapf("code id %d", c.CodeID)
	}
	if k.HasContractInfo(ctx, contractAddr) {
		return errorsmod.Wrapf(types.ErrDuplicate, "contract: %s", contractAddr)
	}
	if len(historyEntries) == 0 {
		return types.ErrEmpty.Wrap("contract history")
	}

	creatorAddress, err := sdk.AccAddressFromBech32(c.Creator)
	if err != nil {
		return err
	}

	err = k.appendToContractHistory(ctx, contractAddr, historyEntries...)
	if err != nil {
		return err
	}
	k.mustStoreContractInfo(ctx, contractAddr, c)
	err = k.addToContractCodeSecondaryIndex(ctx, contractAddr, historyEntries[len(historyEntries)-1])
	if err != nil {
		return err
	}
	err = k.addToContractCreatorSecondaryIndex(ctx, creatorAddress, historyEntries[0].Updated, contractAddr)
	if err != nil {
		return err
	}
	return k.importContractState(ctx, contractAddr, state)
}

func (k Keeper) newQueryHandler(ctx sdk.Context, contractAddress sdk.AccAddress) QueryHandler {
	return NewQueryHandler(ctx, k.wasmVMQueryHandler, contractAddress, k.gasRegister)
}

// MultipliedGasMeter wraps the GasMeter from context and multiplies all reads by out defined multiplier
type MultipliedGasMeter struct {
	originalMeter storetypes.GasMeter
	GasRegister   types.GasRegister
}

func NewMultipliedGasMeter(originalMeter storetypes.GasMeter, gr types.GasRegister) MultipliedGasMeter {
	return MultipliedGasMeter{originalMeter: originalMeter, GasRegister: gr}
}

var _ wasmvm.GasMeter = MultipliedGasMeter{}

func (m MultipliedGasMeter) GasConsumed() storetypes.Gas {
	return m.GasRegister.ToWasmVMGas(m.originalMeter.GasConsumed())
}

func (k Keeper) gasMeter(ctx sdk.Context) MultipliedGasMeter {
	return NewMultipliedGasMeter(ctx.GasMeter(), k.gasRegister)
}

// Logger returns a module-specific logger.
func (k Keeper) Logger(ctx sdk.Context) log.Logger {
	return moduleLogger(ctx)
}

func moduleLogger(ctx sdk.Context) log.Logger {
	return ctx.Logger().With("module", fmt.Sprintf("x/%s", types.ModuleName))
}

// Querier creates a new grpc querier instance
func Querier(k *Keeper) *GrpcQuerier {
	return NewGrpcQuerier(k.cdc, k.storeService, k, k.queryGasLimit)
}

// QueryGasLimit returns the gas limit for smart queries.
func (k Keeper) QueryGasLimit() storetypes.Gas {
	return k.queryGasLimit
}

// BankCoinTransferrer replicates the cosmos-sdk behavior as in
// https://github.com/cosmos/cosmos-sdk/blob/v0.41.4/x/bank/keeper/msg_server.go#L26
type BankCoinTransferrer struct {
	keeper types.BankKeeper
}

func NewBankCoinTransferrer(keeper types.BankKeeper) BankCoinTransferrer {
	return BankCoinTransferrer{
		keeper: keeper,
	}
}

// TransferCoins transfers coins from source to destination account when coin send was enabled for them and the recipient
// is not in the blocked address list.
func (c BankCoinTransferrer) TransferCoins(parentCtx sdk.Context, fromAddr, toAddr sdk.AccAddress, amount sdk.Coins) error {
	em := sdk.NewEventManager()
	ctx := parentCtx.WithEventManager(em)
	if err := c.keeper.IsSendEnabledCoins(ctx, amount...); err != nil {
		return err
	}
	if c.keeper.BlockedAddr(toAddr) {
		return errorsmod.Wrapf(sdkerrors.ErrUnauthorized, "%s is not allowed to receive funds", toAddr.String())
	}

	sdkerr := c.keeper.SendCoins(ctx, fromAddr, toAddr, amount)
	if sdkerr != nil {
		return sdkerr
	}
	for _, e := range em.Events() {
		if e.Type == sdk.EventTypeMessage { // skip messages as we talk to the keeper directly
			continue
		}
		parentCtx.EventManager().EmitEvent(e)
	}
	return nil
}

var _ AccountPruner = VestingCoinBurner{}

// VestingCoinBurner default implementation for AccountPruner to burn the coins
type VestingCoinBurner struct {
	bank types.BankKeeper
}

// NewVestingCoinBurner constructor
func NewVestingCoinBurner(bank types.BankKeeper) VestingCoinBurner {
	if bank == nil {
		panic("bank keeper must not be nil")
	}
	return VestingCoinBurner{bank: bank}
}

// CleanupExistingAccount accepts only vesting account types to burns all their original vesting coin balances.
// Other account types will be rejected and returned as unhandled.
func (b VestingCoinBurner) CleanupExistingAccount(ctx sdk.Context, existingAcc sdk.AccountI) (handled bool, err error) {
	v, ok := existingAcc.(vestingexported.VestingAccount)
	if !ok {
		return false, nil
	}

	ctx = ctx.WithGasMeter(storetypes.NewInfiniteGasMeter())
	coinsToBurn := sdk.NewCoins()
	for _, orig := range v.GetOriginalVesting() { // focus on the coin denoms that were setup originally; getAllBalances has some issues
		coinsToBurn = append(coinsToBurn, b.bank.GetBalance(ctx, existingAcc.GetAddress(), orig.Denom))
	}
	if err := b.bank.SendCoinsFromAccountToModule(ctx, existingAcc.GetAddress(), types.ModuleName, coinsToBurn); err != nil {
		return false, errorsmod.Wrap(err, "prune account balance")
	}
	if err := b.bank.BurnCoins(ctx, types.ModuleName, coinsToBurn); err != nil {
		return false, errorsmod.Wrap(err, "burn account balance")
	}
	return true, nil
}

type msgDispatcher interface {
	DispatchSubmessages(ctx sdk.Context, contractAddr sdk.AccAddress, ibcPort string, msgs []wasmvmtypes.SubMsg) ([]byte, error)
}

// DefaultWasmVMContractResponseHandler default implementation that first dispatches submessage then normal messages.
// The Submessage execution may include a success/failure response handling by the contract that can overwrite the
// original
type DefaultWasmVMContractResponseHandler struct {
	md msgDispatcher
}

func NewDefaultWasmVMContractResponseHandler(md msgDispatcher) *DefaultWasmVMContractResponseHandler {
	return &DefaultWasmVMContractResponseHandler{md: md}
}

// Handle processes the data returned by a contract invocation.
func (h DefaultWasmVMContractResponseHandler) Handle(ctx sdk.Context, contractAddr sdk.AccAddress, ibcPort string, messages []wasmvmtypes.SubMsg, origRspData []byte) ([]byte, error) {
	result := origRspData
	switch rsp, err := h.md.DispatchSubmessages(ctx, contractAddr, ibcPort, messages); {
	case err != nil:
		return nil, err
	case rsp != nil:
		result = rsp
	}
	return result, nil
}
