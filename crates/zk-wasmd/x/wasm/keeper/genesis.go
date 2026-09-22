package keeper

import (
	"context"

	abci "github.com/cometbft/cometbft/abci/types"

	errorsmod "cosmossdk.io/errors"

	sdk "github.com/cosmos/cosmos-sdk/types"

	"github.com/CosmWasm/wasmd/x/wasm/types"
)

// ValidatorSetSource is a subset of the staking keeper
type ValidatorSetSource interface {
	ApplyAndReturnValidatorSetUpdates(context.Context) (updates []abci.ValidatorUpdate, err error)
}

// InitGenesis sets supply information for genesis.
//
// CONTRACT: all types of accounts must have been already initialized/created
func InitGenesis(ctx sdk.Context, keeper *Keeper, data types.GenesisState) ([]abci.ValidatorUpdate, error) {
	contractKeeper := NewGovPermissionKeeper(keeper)
	err := keeper.SetParams(ctx, data.Params)
	if err != nil {
		return nil, errorsmod.Wrapf(err, "set params")
	}

	// Fail fast: param SHA256 / footer / circuit_key alignment before writing state.
	if err := validateGenesisParamCircuitCrossRefs(data); err != nil {
		return nil, errorsmod.Wrap(types.ErrInvalid, err.Error())
	}

	var maxCodeID uint64
	for i, code := range data.Codes {
		err := keeper.importCode(ctx, code.CodeID, code.CodeInfo, code.CodeBytes)
		if err != nil {
			return nil, errorsmod.Wrapf(err, "code %d with id: %d", i, code.CodeID)
		}
		if code.CodeID > maxCodeID {
			maxCodeID = code.CodeID
		}
		if code.Pinned {
			if err := contractKeeper.PinCode(ctx, code.CodeID); err != nil {
				return nil, errorsmod.Wrapf(err, "contract number %d", i)
			}
		}
	}

	// Standalone params first so StoreParam warms zk_param/ before circuits.
	var maxParamID uint64
	for i, p := range data.VkParams {
		info := types.VkParamInfoResponse{
			VkID:     p.ParamID,
			Creator:  p.Creator,
			DataHash: p.ParamKey,
		}
		if err := keeper.importVkParam(ctx, p.ParamID, info, p.ParamBytes); err != nil {
			return nil, errorsmod.Wrapf(err, "vk_param %d id %d", i, p.ParamID)
		}
		if p.ParamID > maxParamID {
			maxParamID = p.ParamID
		}
	}

	var maxCircuitID uint64
	for i, code := range data.Circuits {
		err := keeper.importCircuit(ctx, code.ZkID, code.ZkInfo, code.ZkBytes)
		if err != nil {
			return nil, errorsmod.Wrapf(err, "circuit %d with idzk-: %d", i, code.ZkID)
		}
		if code.ZkID > maxCircuitID {
			maxCircuitID = code.ZkID
		}
		if code.Pinned {
			if err := contractKeeper.PinCircuit(ctx, code.ZkID); err != nil {
				return nil, errorsmod.Wrapf(err, "contract number %d", i)
			}
		}
	}
	_ = maxParamID // validated via sequence import below when present

	for i, contract := range data.Contracts {
		contractAddr, err := sdk.AccAddressFromBech32(contract.ContractAddress)
		if err != nil {
			return nil, errorsmod.Wrapf(err, "address in contract number %d", i)
		}
		err = keeper.importContract(ctx, contractAddr, &contract.ContractInfo, contract.ContractState, contract.ContractCodeHistory)
		if err != nil {
			return nil, errorsmod.Wrapf(err, "contract number %d", i)
		}
	}

	for i, seq := range data.Sequences {
		err := keeper.importAutoIncrementID(ctx, seq.IDKey, seq.Value)
		if err != nil {
			return nil, errorsmod.Wrapf(err, "sequence number %d", i)
		}
	}

	// sanity check seq values
	seqVal, err := keeper.PeekAutoIncrementID(ctx, types.KeySequenceCodeID)
	if err != nil {
		return nil, err
	}
	if seqVal <= maxCodeID {
		return nil, errorsmod.Wrapf(types.ErrInvalid, "seq %s with value: %d must be greater than: %d ", string(types.KeySequenceCodeID), seqVal, maxCodeID)
	}

	// sanity check seq values
	circuitSeqVal, err := keeper.PeekAutoIncrementID(ctx, types.KeySequenceCircuitID)
	if err != nil {
		return nil, err
	}
	if circuitSeqVal <= maxCircuitID {
		return nil, errorsmod.Wrapf(types.ErrInvalid, "circuitSeqVal %s with value: %d must be greater than: %d ", string(types.KeySequenceCircuitID), seqVal, maxCodeID)
	}

	// ensure next classic address is unused so that we know the sequence is good
	rCtx, _ := ctx.CacheContext()
	seqVal, err = keeper.PeekAutoIncrementID(rCtx, types.KeySequenceInstanceID)
	if err != nil {
		return nil, err
	}
	addr := keeper.ClassicAddressGenerator()(rCtx, seqVal, nil)
	if keeper.HasContractInfo(ctx, addr) {
		return nil, errorsmod.Wrapf(types.ErrInvalid, "value: %d for seq %s was used already", seqVal, string(types.KeySequenceInstanceID))
	}
	return nil, nil
}

// ExportGenesis returns a GenesisState for a given context and keeper.
func ExportGenesis(ctx sdk.Context, keeper *Keeper) *types.GenesisState {
	var genState types.GenesisState

	genState.Params = keeper.GetParams(ctx)

	keeper.IterateCodeInfos(ctx, func(codeID uint64, info types.CodeInfo) bool {
		bytecode, err := keeper.GetByteCode(ctx, codeID)
		if err != nil {
			panic(err)
		}
		genState.Codes = append(genState.Codes, types.Code{
			CodeID:    codeID,
			CodeInfo:  info,
			CodeBytes: bytecode,
			Pinned:    keeper.IsPinnedCode(ctx, codeID),
		})
		return false
	})

	// Standalone params (StoreVkParam) — raw bytes for StoreParam on import only.
	// Keyed by param_key so we can backfill from circuits without duplicates.
	exportedParamKeys := make(map[string]struct{})
	keeper.IterateVkParamInfos(ctx, func(paramID uint64, info types.VkParamInfoResponse) bool {
		blob, err := keeper.getVkParamBytes(ctx, paramID)
		if err != nil {
			panic(err)
		}
		genState.VkParams = append(genState.VkParams, types.VkParam{
			ParamID:    paramID,
			ParamKey:   info.DataHash, // 36-byte wasmvm param_key
			Creator:    info.Creator,
			ParamBytes: blob,
		})
		if len(info.DataHash) == 36 {
			exportedParamKeys[string(info.DataHash)] = struct{}{}
		}
		return false
	})

	// Export circuits with canonical app-state bytes for state sync / genesis import.
	// ZkBytes is the source of truth used by InitGenesis → importCircuit → StoreCircuitUnchecked.
	// Also backfill VkParams for any circuit param half not already exported, so genesis
	// always satisfies circuit → vk_param cross-references on re-import.
	nextSyntheticParamID := uint64(0)
	for _, p := range genState.VkParams {
		if p.ParamID > nextSyntheticParamID {
			nextSyntheticParamID = p.ParamID
		}
	}
	keeper.IterateCircuitInfos(ctx, func(zkID uint64, info types.CircuitInfo) bool {
		blob, err := keeper.GetCircuit(ctx, zkID)
		if err != nil {
			panic(err)
		}
		genState.Circuits = append(genState.Circuits, types.Circuit{
			ZkID:    zkID,
			ZkInfo:  info,
			ZkBytes: blob,
			Pinned:  keeper.IsPinnedCircuit(ctx, zkID),
		})
		if len(info.CircuitHash) >= 36 {
			paramHalf := info.CircuitHash[:36]
			if _, already := exportedParamKeys[string(paramHalf)]; !already {
				if paramBytes, ok := circuitParamBytes(blob, info); ok {
					nextSyntheticParamID++
					genState.VkParams = append(genState.VkParams, types.VkParam{
						ParamID:    nextSyntheticParamID,
						ParamKey:   append([]byte(nil), paramHalf...),
						Creator:    info.Creator,
						ParamBytes: append([]byte(nil), paramBytes...),
					})
					exportedParamKeys[string(paramHalf)] = struct{}{}
				}
			}
		}
		return false
	})

	keeper.IterateContractInfo(ctx, func(addr sdk.AccAddress, contract types.ContractInfo) bool {
		var state []types.Model
		keeper.IterateContractState(ctx, addr, func(key, value []byte) bool {
			state = append(state, types.Model{Key: key, Value: value})
			return false
		})

		contractCodeHistory := keeper.GetContractHistory(ctx, addr)

		genState.Contracts = append(genState.Contracts, types.Contract{
			ContractAddress:     addr.String(),
			ContractInfo:        contract,
			ContractState:       state,
			ContractCodeHistory: contractCodeHistory,
		})
		return false
	})

	for _, k := range [][]byte{
		types.KeySequenceCodeID,
		types.KeySequenceInstanceID,
		types.KeySequenceCircuitID,
		types.KeySequenceVkParamID,
	} {
		store := keeper.storeService.OpenKVStore(ctx)
		has, err := store.Has(k)
		if err != nil {
			panic(err)
		}
		// Peek returns a default of 1 when the key is absent. Importing that
		// default would write a KV the source never had (circuit/vk sequences
		// after a wasm-only genesis).
		if !has {
			continue
		}
		id, err := keeper.PeekAutoIncrementID(ctx, k)
		if err != nil {
			panic(err)
		}
		genState.Sequences = append(genState.Sequences, types.Sequence{
			IDKey: k,
			Value: id,
		})
	}

	return &genState
}
