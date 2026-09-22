package keeper

import (
	"context"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"runtime/debug"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	corestoretypes "cosmossdk.io/core/store"
	errorsmod "cosmossdk.io/errors"

	"github.com/cosmos/cosmos-sdk/codec"
	"github.com/cosmos/cosmos-sdk/runtime"
	"github.com/cosmos/cosmos-sdk/store/v2/prefix"
	storetypes "github.com/cosmos/cosmos-sdk/store/v2/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
	sdkerrors "github.com/cosmos/cosmos-sdk/types/errors"
	"github.com/cosmos/cosmos-sdk/types/query"

	"github.com/CosmWasm/wasmd/x/wasm/types"
)

// DefaultGasCostBuildAddress is the SDK gas cost to build a contract address
const DefaultGasCostBuildAddress = 10

var _ types.QueryServer = &GrpcQuerier{}

type GrpcQuerier struct {
	cdc           codec.Codec
	storeService  corestoretypes.KVStoreService
	keeper        types.ViewKeeper
	queryGasLimit storetypes.Gas
}

// Vk returns metadata and (when available) the reconstructed circuit blob for a vk/zk id.
// Note: this is not param raw bytes — params are never returned from queries.
func (q *GrpcQuerier) Vk(c context.Context, req *types.QueryVkRequest) (*types.QueryVkResponse, error) {
	if req == nil {
		return nil, status.Error(codes.InvalidArgument, "empty request")
	}
	if req.VkId == 0 {
		return nil, errorsmod.Wrap(types.ErrInvalid, "vk id")
	}
	rsp, err := queryCircuit(sdk.UnwrapSDKContext(c), req.VkId, q.keeper)
	switch {
	case err != nil:
		return nil, err
	case rsp == nil:
		return nil, types.ErrNoSuchCircuitFn(req.VkId).Wrapf("vk id %d", req.VkId)
	}
	return &types.QueryVkResponse{
		VkInfoResponse: &types.VkInfoResponse{
			VkID:                  req.VkId,
			CSId:                  0,
			Creator:               rsp.Creator,
			DataHash:              rsp.DataHash,
			InstantiatePermission: rsp.InstantiatePermission,
		},
		Data: rsp.Data,
	}, nil
}

// VkInfo returns verifying-key / circuit metadata only (no raw param bytes).
func (q *GrpcQuerier) VkInfo(c context.Context, req *types.QueryVkInfoRequest) (*types.QueryVkInfoResponse, error) {
	if req == nil {
		return nil, status.Error(codes.InvalidArgument, "empty request")
	}
	if req.VkId == 0 {
		return nil, errorsmod.Wrap(types.ErrInvalid, "vk id")
	}
	info := queryCircuitInfo(sdk.UnwrapSDKContext(c), req.VkId, q.keeper)
	if info == nil {
		return nil, types.ErrNoSuchCircuitFn(req.VkId).Wrapf("vk id %d", req.VkId)
	}
	paramID, _ := q.circuitParamID(c, req.VkId)
	return &types.QueryVkInfoResponse{
		ParamInfo: &types.VkInfoResponse{
			VkID:                  req.VkId,
			CSId:                  paramID,
			Creator:               info.Creator,
			DataHash:              info.DataHash,
			InstantiatePermission: info.InstantiatePermission,
		},
	}, nil
}

// VkParam returns param *metadata only*. Raw param bytes are intentionally omitted.
func (q *GrpcQuerier) VkParam(c context.Context, req *types.QueryVkParamRequest) (*types.QueryVkParamResponse, error) {
	if req == nil {
		return nil, status.Error(codes.InvalidArgument, "empty request")
	}
	if req.ParamId == 0 {
		return nil, errorsmod.Wrap(types.ErrInvalid, "param id")
	}
	info := queryVkParamInfo(sdk.UnwrapSDKContext(c), req.ParamId, q.keeper)
	if info == nil || info.ParamInfo == nil {
		return nil, types.ErrNotFound.Wrapf("vk param %d", req.ParamId)
	}
	// Data is always empty: public API must never return raw param bytes.
	return &types.QueryVkParamResponse{
		VkInfoResponse: info.ParamInfo,
		Data:           nil,
	}, nil
}

// VkParamInfo returns checksums and creator for a stored param set.
func (q *GrpcQuerier) VkParamInfo(c context.Context, req *types.QueryVkParamInfoRequest) (*types.QueryVkParamInfoResponse, error) {
	if req == nil {
		return nil, status.Error(codes.InvalidArgument, "empty request")
	}
	if req.ParamId == 0 {
		return nil, errorsmod.Wrap(types.ErrInvalid, "param id")
	}
	info := queryVkParamInfo(sdk.UnwrapSDKContext(c), req.ParamId, q.keeper)
	if info == nil {
		return nil, types.ErrNotFound.Wrapf("vk param %d", req.ParamId)
	}
	return info, nil
}

// circuitParamID looks up the param_id for a zk/vk id when the keeper supports it.
func (q *GrpcQuerier) circuitParamID(c context.Context, zkID uint64) (uint64, bool) {
	if k, ok := q.keeper.(interface {
		GetCircuitParamID(ctx context.Context, zkID uint64) (uint64, bool)
	}); ok {
		return k.GetCircuitParamID(sdk.UnwrapSDKContext(c), zkID)
	}
	return 0, false
}

// NewGrpcQuerier constructor
func NewGrpcQuerier(cdc codec.Codec, storeService corestoretypes.KVStoreService, keeper types.ViewKeeper, queryGasLimit storetypes.Gas) *GrpcQuerier {
	return &GrpcQuerier{cdc: cdc, storeService: storeService, keeper: keeper, queryGasLimit: queryGasLimit}
}

func (q GrpcQuerier) ContractInfo(c context.Context, req *types.QueryContractInfoRequest) (*types.QueryContractInfoResponse, error) {
	if req == nil {
		return nil, status.Error(codes.InvalidArgument, "empty request")
	}
	contractAddr, err := sdk.AccAddressFromBech32(req.Address)
	if err != nil {
		return nil, err
	}
	rsp, err := queryContractInfo(sdk.UnwrapSDKContext(c), contractAddr, q.keeper)
	switch {
	case err != nil:
		return nil, err
	case rsp == nil:
		return nil, types.ErrNoSuchContractFn(contractAddr.String()).
			Wrapf("address %s", contractAddr.String())
	}
	return rsp, nil
}

func (q GrpcQuerier) ContractHistory(c context.Context, req *types.QueryContractHistoryRequest) (*types.QueryContractHistoryResponse, error) {
	if req == nil {
		return nil, status.Error(codes.InvalidArgument, "empty request")
	}
	contractAddr, err := sdk.AccAddressFromBech32(req.Address)
	if err != nil {
		return nil, err
	}
	paginationParams, err := ensurePaginationParams(req.Pagination)
	if err != nil {
		return nil, err
	}

	ctx := sdk.UnwrapSDKContext(c)
	r := make([]types.ContractCodeHistoryEntry, 0)

	prefixStore := prefix.NewStore(runtime.KVStoreAdapter(q.storeService.OpenKVStore(ctx)), types.GetContractCodeHistoryElementPrefix(contractAddr))
	pageRes, err := query.FilteredPaginate(prefixStore, paginationParams, func(key, value []byte, accumulate bool) (bool, error) {
		if accumulate {
			var e types.ContractCodeHistoryEntry
			if err := q.cdc.Unmarshal(value, &e); err != nil {
				return false, err
			}
			r = append(r, e)
		}
		return true, nil
	})
	if err != nil {
		return nil, err
	}
	return &types.QueryContractHistoryResponse{
		Entries:    r,
		Pagination: pageRes,
	}, nil
}

// ContractsByCode lists all smart contracts for a code id
func (q GrpcQuerier) ContractsByCode(c context.Context, req *types.QueryContractsByCodeRequest) (*types.QueryContractsByCodeResponse, error) {
	if req == nil {
		return nil, status.Error(codes.InvalidArgument, "empty request")
	}
	if req.CodeId == 0 {
		return nil, errorsmod.Wrap(types.ErrInvalid, "code id")
	}
	paginationParams, err := ensurePaginationParams(req.Pagination)
	if err != nil {
		return nil, err
	}

	ctx := sdk.UnwrapSDKContext(c)
	r := make([]string, 0)

	prefixStore := prefix.NewStore(runtime.KVStoreAdapter(q.storeService.OpenKVStore(ctx)), types.GetContractByCodeIDSecondaryIndexPrefix(req.CodeId))
	pageRes, err := query.FilteredPaginate(prefixStore, paginationParams, func(key, value []byte, accumulate bool) (bool, error) {
		if accumulate {
			var contractAddr sdk.AccAddress = key[types.AbsoluteTxPositionLen:]
			r = append(r, contractAddr.String())
		}
		return true, nil
	})
	if err != nil {
		return nil, err
	}
	return &types.QueryContractsByCodeResponse{
		Contracts:  r,
		Pagination: pageRes,
	}, nil
}

func (q GrpcQuerier) AllContractState(c context.Context, req *types.QueryAllContractStateRequest) (*types.QueryAllContractStateResponse, error) {
	if req == nil {
		return nil, status.Error(codes.InvalidArgument, "empty request")
	}

	contractAddr, err := sdk.AccAddressFromBech32(req.Address)
	if err != nil {
		return nil, err
	}
	paginationParams, err := ensurePaginationParams(req.Pagination)
	if err != nil {
		return nil, err
	}

	ctx := sdk.UnwrapSDKContext(c)
	if !q.keeper.HasContractInfo(ctx, contractAddr) {
		return nil, types.ErrNoSuchContractFn(contractAddr.String()).
			Wrapf("address %s", contractAddr.String())
	}

	r := make([]types.Model, 0)
	prefixStore := prefix.NewStore(runtime.KVStoreAdapter(q.storeService.OpenKVStore(ctx)), types.GetContractStorePrefix(contractAddr))
	pageRes, err := query.FilteredPaginate(prefixStore, paginationParams, func(key, value []byte, accumulate bool) (bool, error) {
		if accumulate {
			r = append(r, types.Model{
				Key:   key,
				Value: value,
			})
		}
		return true, nil
	})
	if err != nil {
		return nil, err
	}
	return &types.QueryAllContractStateResponse{
		Models:     r,
		Pagination: pageRes,
	}, nil
}

func (q GrpcQuerier) RawContractState(c context.Context, req *types.QueryRawContractStateRequest) (*types.QueryRawContractStateResponse, error) {
	if req == nil {
		return nil, status.Error(codes.InvalidArgument, "empty request")
	}
	ctx := sdk.UnwrapSDKContext(c)

	contractAddr, err := sdk.AccAddressFromBech32(req.Address)
	if err != nil {
		return nil, err
	}

	if !q.keeper.HasContractInfo(ctx, contractAddr) {
		return nil, types.ErrNoSuchContractFn(contractAddr.String()).
			Wrapf("address %s", contractAddr.String())
	}
	rsp := q.keeper.QueryRaw(ctx, contractAddr, req.QueryData)
	return &types.QueryRawContractStateResponse{Data: rsp}, nil
}

func (q GrpcQuerier) SmartContractState(c context.Context, req *types.QuerySmartContractStateRequest) (rsp *types.QuerySmartContractStateResponse, err error) {
	if req == nil {
		return nil, status.Error(codes.InvalidArgument, "empty request")
	}
	if err := req.QueryData.ValidateBasic(); err != nil {
		return nil, status.Error(codes.InvalidArgument, "invalid query data")
	}
	contractAddr, err := sdk.AccAddressFromBech32(req.Address)
	if err != nil {
		return nil, err
	}

	// limit the gas to the queryGasLimit or the remaining gas, whichever is smaller
	ctx := sdk.UnwrapSDKContext(c)
	gasLimit := min(ctx.GasMeter().GasRemaining(), q.queryGasLimit)
	ctx = ctx.WithGasMeter(storetypes.NewGasMeter(gasLimit))
	// recover from out-of-gas panic
	defer func() {
		if r := recover(); r != nil {
			switch rType := r.(type) {
			case storetypes.ErrorOutOfGas:
				err = errorsmod.Wrapf(sdkerrors.ErrOutOfGas,
					"out of gas in location: %v; gasWanted: %d, gasUsed: %d",
					rType.Descriptor, ctx.GasMeter().Limit(), ctx.GasMeter().GasConsumed(),
				)
			default:
				err = sdkerrors.ErrPanic
			}
			rsp = nil
			moduleLogger(ctx).
				Debug("smart query contract",
					"error", "recovering panic",
					"contract-address", req.Address,
					"stacktrace", string(debug.Stack()))
		}
	}()

	bz, err := q.keeper.QuerySmart(ctx, contractAddr, req.QueryData)
	switch {
	case err != nil:
		return nil, err
	case bz == nil:
		return nil, types.ErrNoSuchContractFn(contractAddr.String()).
			Wrapf("address %s", contractAddr.String())
	}
	return &types.QuerySmartContractStateResponse{Data: bz}, nil
}

func (q GrpcQuerier) Code(c context.Context, req *types.QueryCodeRequest) (*types.QueryCodeResponse, error) {
	if req == nil {
		return nil, status.Error(codes.InvalidArgument, "empty request")
	}
	if req.CodeId == 0 {
		return nil, errorsmod.Wrap(types.ErrInvalid, "code id")
	}
	rsp, err := queryCode(sdk.UnwrapSDKContext(c), req.CodeId, q.keeper)
	switch {
	case err != nil:
		return nil, err
	case rsp == nil:
		return nil, types.ErrNoSuchCodeFn(req.CodeId).Wrapf("code id %d", req.CodeId)
	}
	return &types.QueryCodeResponse{
		CodeInfoResponse: rsp.CodeInfoResponse,
		Data:             rsp.Data,
	}, nil
}

func (q GrpcQuerier) Codes(c context.Context, req *types.QueryCodesRequest) (*types.QueryCodesResponse, error) {
	if req == nil {
		return nil, status.Error(codes.InvalidArgument, "empty request")
	}
	paginationParams, err := ensurePaginationParams(req.Pagination)
	if err != nil {
		return nil, err
	}

	ctx := sdk.UnwrapSDKContext(c)
	r := make([]types.CodeInfoResponse, 0)
	prefixStore := prefix.NewStore(runtime.KVStoreAdapter(q.storeService.OpenKVStore(ctx)), types.CodeKeyPrefix)
	pageRes, err := query.FilteredPaginate(prefixStore, paginationParams, func(key, value []byte, accumulate bool) (bool, error) {
		if accumulate {
			var c types.CodeInfo
			if err := q.cdc.Unmarshal(value, &c); err != nil {
				return false, err
			}
			r = append(r, types.CodeInfoResponse{
				CodeID:                binary.BigEndian.Uint64(key),
				Creator:               c.Creator,
				DataHash:              c.CodeHash,
				InstantiatePermission: c.InstantiateConfig,
			})
		}
		return true, nil
	})
	if err != nil {
		return nil, err
	}
	return &types.QueryCodesResponse{CodeInfos: r, Pagination: pageRes}, nil
}

func (q GrpcQuerier) CodeInfo(c context.Context, req *types.QueryCodeInfoRequest) (*types.QueryCodeInfoResponse, error) {
	if req == nil {
		return nil, status.Error(codes.InvalidArgument, "empty request")
	}
	if req.CodeId == 0 {
		return nil, errorsmod.Wrap(types.ErrInvalid, "code id")
	}
	info := queryCodeInfo(sdk.UnwrapSDKContext(c), req.CodeId, q.keeper)
	if info == nil {
		return nil, types.ErrNoSuchCodeFn(req.CodeId).Wrapf("code id %d", req.CodeId)
	}
	return &types.QueryCodeInfoResponse{
		CodeID:                info.CodeID,
		Creator:               info.Creator,
		Checksum:              info.DataHash,
		InstantiatePermission: info.InstantiatePermission,
	}, nil
}

func (q GrpcQuerier) Circuit(c context.Context, req *types.QueryCircuitRequest) (*types.QueryCircuitResponse, error) {
	if req == nil {
		return nil, status.Error(codes.InvalidArgument, "empty request")
	}
	if req.ZkId == 0 {
		return nil, errorsmod.Wrap(types.ErrInvalid, "zk id")
	}
	rsp, err := queryCircuit(sdk.UnwrapSDKContext(c), req.ZkId, q.keeper)
	switch {
	case err != nil:
		return nil, err
	case rsp == nil:
		return nil, types.ErrNoSuchCircuitFn(req.ZkId).Wrapf("zk id %d", req.ZkId)
	}
	return &types.QueryCircuitResponse{
		CircuitInfoResponse: rsp.CircuitInfoResponse,
		Data:                rsp.Data,
	}, nil
}
func (q GrpcQuerier) CircuitInfo(c context.Context, req *types.QueryCircuitInfoRequest) (*types.QueryCircuitInfoResponse, error) {
	if req == nil {
		return nil, status.Error(codes.InvalidArgument, "empty request")
	}
	if req.ZkId == 0 {
		return nil, errorsmod.Wrap(types.ErrInvalid, "zk id")
	}
	info := queryCircuitInfo(sdk.UnwrapSDKContext(c), req.ZkId, q.keeper)
	if info == nil {
		return nil, types.ErrNoSuchCodeFn(req.ZkId).Wrapf("code id %d", req.ZkId)
	}
	return &types.QueryCircuitInfoResponse{
		ZkID:                  info.ZkID,
		Creator:               info.Creator,
		Checksum:              info.DataHash,
		InstantiatePermission: info.InstantiatePermission,
	}, nil
}

func queryContractInfo(ctx sdk.Context, addr sdk.AccAddress, keeper types.ViewKeeper) (*types.QueryContractInfoResponse, error) {
	info := keeper.GetContractInfo(ctx, addr)
	if info == nil {
		return nil, types.ErrNoSuchContractFn(addr.String()).
			Wrapf("address %s", addr.String())
	}
	return &types.QueryContractInfoResponse{
		Address:      addr.String(),
		ContractInfo: *info,
	}, nil
}

func queryCode(ctx sdk.Context, codeID uint64, keeper types.ViewKeeper) (*types.QueryCodeResponse, error) {
	info := queryCodeInfo(ctx, codeID, keeper)
	if info == nil {
		// nil, nil leads to 404 in rest handler
		return nil, nil
	}

	code, err := keeper.GetByteCode(ctx, codeID)
	if err != nil {
		return nil, errorsmod.Wrap(err, "loading wasm code")
	}

	return &types.QueryCodeResponse{CodeInfoResponse: info, Data: code}, nil
}

func queryCodeInfo(ctx sdk.Context, codeID uint64, keeper types.ViewKeeper) *types.CodeInfoResponse {
	if codeID == 0 {
		return nil
	}
	res := keeper.GetCodeInfo(ctx, codeID)
	if res == nil {
		return nil
	}
	info := types.CodeInfoResponse{
		CodeID:                codeID,
		Creator:               res.Creator,
		DataHash:              res.CodeHash,
		InstantiatePermission: res.InstantiateConfig,
	}
	return &info
}

func queryCircuit(ctx sdk.Context, zkID uint64, keeper types.ViewKeeper) (*types.QueryCircuitResponse, error) {
	info := queryCircuitInfo(ctx, zkID, keeper)
	if info == nil {
		// nil, nil leads to 404 in rest handler
		return nil, nil
	}

	code, err := keeper.GetCircuit(ctx, zkID)
	if err != nil {
		return nil, err
	}
	if code == nil {
		return nil, types.ErrNoSuchCircuitFn(zkID)
	}

	return &types.QueryCircuitResponse{CircuitInfoResponse: info, Data: code}, nil
}

// queryVkParam is intentionally metadata-only (no raw param bytes).
func queryVkParam(ctx sdk.Context, vkParamId uint64, keeper types.ViewKeeper) (*types.QueryVkParamResponse, error) {
	info := queryVkParamInfo(ctx, vkParamId, keeper)
	if info == nil || info.ParamInfo == nil {
		return nil, nil
	}
	return &types.QueryVkParamResponse{
		VkInfoResponse: info.ParamInfo,
		Data:           nil, // never expose raw params
	}, nil
}

func queryVkParamInfo(ctx sdk.Context, paramID uint64, keeper types.ViewKeeper) *types.QueryVkParamInfoResponse {
	if paramID == 0 {
		return nil
	}
	res := keeper.GetVkParamInfo(ctx, paramID)
	if res == nil {
		return nil
	}
	// Map VkParamInfoResponse into the nested VkInfoResponse used by generated query types.
	return &types.QueryVkParamInfoResponse{
		ParamInfo: &types.VkInfoResponse{
			VkID:                  res.VkID,
			CSId:                  res.VkID, // param_id; dedicated field lands with next proto regen
			Creator:               res.Creator,
			DataHash:              res.DataHash,
			InstantiatePermission: res.InstantiatePermission,
		},
	}
}

func queryCircuitInfo(ctx sdk.Context, zkID uint64, keeper types.ViewKeeper) *types.CircuitInfoResponse {
	if zkID == 0 {
		return nil
	}
	res := keeper.GetCircuitInfo(ctx, zkID)
	if res == nil {
		return nil
	}
	info := types.CircuitInfoResponse{
		ZkID:                  zkID,
		Creator:               res.Creator,
		DataHash:              res.CircuitHash,
		InstantiatePermission: res.InstantiateConfig,
	}
	return &info
}

func (q GrpcQuerier) PinnedCodes(c context.Context, req *types.QueryPinnedCodesRequest) (*types.QueryPinnedCodesResponse, error) {
	if req == nil {
		return nil, status.Error(codes.InvalidArgument, "empty request")
	}
	paginationParams, err := ensurePaginationParams(req.Pagination)
	if err != nil {
		return nil, err
	}

	ctx := sdk.UnwrapSDKContext(c)
	r := make([]uint64, 0)

	prefixStore := prefix.NewStore(runtime.KVStoreAdapter(q.storeService.OpenKVStore(ctx)), types.PinnedCodeIndexPrefix)
	pageRes, err := query.FilteredPaginate(prefixStore, paginationParams, func(key, _ []byte, accumulate bool) (bool, error) {
		if accumulate {
			r = append(r, sdk.BigEndianToUint64(key))
		}
		return true, nil
	})
	if err != nil {
		return nil, err
	}
	return &types.QueryPinnedCodesResponse{
		CodeIDs:    r,
		Pagination: pageRes,
	}, nil
}

func (q GrpcQuerier) PinnedCircuits(c context.Context, req *types.QueryPinnedCircuitsRequest) (*types.QueryPinnedCircuitsResponse, error) {
	if req == nil {
		return nil, status.Error(codes.InvalidArgument, "empty request")
	}
	paginationParams, err := ensurePaginationParams(req.Pagination)
	if err != nil {
		return nil, err
	}

	ctx := sdk.UnwrapSDKContext(c)
	r := make([]uint64, 0)

	prefixStore := prefix.NewStore(runtime.KVStoreAdapter(q.storeService.OpenKVStore(ctx)), types.PinnedCircuitsIndexPrefix)
	pageRes, err := query.FilteredPaginate(prefixStore, paginationParams, func(key, _ []byte, accumulate bool) (bool, error) {
		if accumulate {
			r = append(r, sdk.BigEndianToUint64(key))
		}
		return true, nil
	})
	if err != nil {
		return nil, err
	}
	return &types.QueryPinnedCircuitsResponse{
		ZkIDs:      r,
		Pagination: pageRes,
	}, nil
}

// Params returns params of the module.
func (q GrpcQuerier) Params(c context.Context, _ *types.QueryParamsRequest) (*types.QueryParamsResponse, error) {
	ctx := sdk.UnwrapSDKContext(c)
	params := q.keeper.GetParams(ctx)
	return &types.QueryParamsResponse{Params: params}, nil
}

func (q GrpcQuerier) ContractsByCreator(c context.Context, req *types.QueryContractsByCreatorRequest) (*types.QueryContractsByCreatorResponse, error) {
	if req == nil {
		return nil, status.Error(codes.InvalidArgument, "empty request")
	}
	paginationParams, err := ensurePaginationParams(req.Pagination)
	if err != nil {
		return nil, err
	}

	ctx := sdk.UnwrapSDKContext(c)
	contracts := make([]string, 0)

	creatorAddress, err := sdk.AccAddressFromBech32(req.CreatorAddress)
	if err != nil {
		return nil, err
	}
	prefixStore := prefix.NewStore(runtime.KVStoreAdapter(q.storeService.OpenKVStore(ctx)), types.GetContractsByCreatorPrefix(creatorAddress))
	pageRes, err := query.FilteredPaginate(prefixStore, paginationParams, func(key, _ []byte, accumulate bool) (bool, error) {
		if accumulate {
			accAddress := sdk.AccAddress(key[types.AbsoluteTxPositionLen:])
			contracts = append(contracts, accAddress.String())
		}
		return true, nil
	})
	if err != nil {
		return nil, err
	}

	return &types.QueryContractsByCreatorResponse{
		ContractAddresses: contracts,
		Pagination:        pageRes,
	}, nil
}

// max limit to pagination queries
const maxResultEntries = 100

var errLegacyPaginationUnsupported = status.Error(codes.InvalidArgument, "offset and count queries not supported")

// ensure that pagination is done via key iterator with reasonable limit
func ensurePaginationParams(req *query.PageRequest) (*query.PageRequest, error) {
	if req == nil {
		return &query.PageRequest{
			Key:   nil,
			Limit: query.DefaultLimit,
		}, nil
	}
	if req.Offset != 0 || req.CountTotal {
		return nil, errLegacyPaginationUnsupported
	}
	if req.Limit > maxResultEntries || req.Limit <= 0 {
		req.Limit = maxResultEntries
	}
	return req, nil
}

func (q GrpcQuerier) WasmLimitsConfig(c context.Context, req *types.QueryWasmLimitsConfigRequest) (*types.QueryWasmLimitsConfigResponse, error) {
	json, err := json.Marshal(q.keeper.GetWasmLimits())
	if err != nil {
		return nil, err
	}

	return &types.QueryWasmLimitsConfigResponse{
		Config: string(json),
	}, nil
}

func (q GrpcQuerier) BuildAddress(c context.Context, req *types.QueryBuildAddressRequest) (*types.QueryBuildAddressResponse, error) {
	ctx := sdk.UnwrapSDKContext(c)
	defer ctx.GasMeter().ConsumeGas(DefaultGasCostBuildAddress, "build address")
	return BuildAddressPredictable(req)
}

func BuildAddressPredictable(req *types.QueryBuildAddressRequest) (*types.QueryBuildAddressResponse, error) {
	if req == nil {
		return nil, status.Error(codes.InvalidArgument, "empty request")
	}
	codeHash, err := hex.DecodeString(req.CodeHash)
	if err != nil {
		return nil, fmt.Errorf("invalid code hash: %w", err)
	}
	creator, err := sdk.AccAddressFromBech32(req.CreatorAddress)
	if err != nil {
		return nil, fmt.Errorf("invalid creator address: %w", err)
	}
	salt, err := hex.DecodeString(req.Salt)
	if err != nil {
		return nil, fmt.Errorf("invalid salt: %w", err)
	}
	if len(salt) == 0 {
		return nil, status.Error(codes.InvalidArgument, "empty salt")
	}

	if req.InitArgs == nil {
		return &types.QueryBuildAddressResponse{
			Address: BuildContractAddressPredictable(codeHash, creator, salt, []byte{}).String(),
		}, nil
	}
	initMsg := types.RawContractMessage(req.InitArgs)
	if err := initMsg.ValidateBasic(); err != nil {
		return nil, err
	}
	return &types.QueryBuildAddressResponse{
		Address: BuildContractAddressPredictable(codeHash, creator, salt, initMsg).String(),
	}, nil
}
