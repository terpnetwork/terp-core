package keeper

import (
	"context"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/terpnetwork/terp-core/v5/x/hashmerchant/types"
)

var _ types.QueryServer = Keeper{}

// Params returns the module parameters.
func (k Keeper) Params(goCtx context.Context, _ *types.QueryParamsRequest) (*types.QueryParamsResponse, error) {
	p, err := k.GetParams(goCtx)
	if err != nil {
		return nil, err
	}
	return &types.QueryParamsResponse{Params: p}, nil
}

// RegisteredChain returns a single registered chain.
func (k Keeper) RegisteredChain(goCtx context.Context, req *types.QueryRegisteredChainRequest) (*types.QueryRegisteredChainResponse, error) {
	if req == nil || req.ChainUid == "" {
		return nil, status.Error(codes.InvalidArgument, "chain_uid required")
	}
	c, err := k.GetRegisteredChain(goCtx, req.ChainUid)
	if err != nil {
		return nil, err
	}
	return &types.QueryRegisteredChainResponse{Chain: c}, nil
}

// RegisteredChains lists all registered chains.
func (k Keeper) RegisteredChains(goCtx context.Context, _ *types.QueryRegisteredChainsRequest) (*types.QueryRegisteredChainsResponse, error) {
	var chains []types.RegisteredChain
	k.IterateRegisteredChains(goCtx, func(c types.RegisteredChain) bool {
		chains = append(chains, c)
		return false
	})
	return &types.QueryRegisteredChainsResponse{Chains: chains}, nil
}

// RegisteredContract returns a single registered contract.
func (k Keeper) RegisteredContract(goCtx context.Context, req *types.QueryRegisteredContractRequest) (*types.QueryRegisteredContractResponse, error) {
	if req == nil || req.ContractAddr == "" {
		return nil, status.Error(codes.InvalidArgument, "contract_addr required")
	}
	c, err := k.GetRegisteredContract(goCtx, req.ContractAddr)
	if err != nil {
		return nil, err
	}
	return &types.QueryRegisteredContractResponse{Contract: c}, nil
}

// RegisteredContracts lists all registered contracts.
func (k Keeper) RegisteredContracts(goCtx context.Context, _ *types.QueryRegisteredContractsRequest) (*types.QueryRegisteredContractsResponse, error) {
	var contracts []types.RegisteredContract
	k.IterateRegisteredContracts(goCtx, func(c types.RegisteredContract) bool {
		contracts = append(contracts, c)
		return false
	})
	return &types.QueryRegisteredContractsResponse{Contracts: contracts}, nil
}

// HashRoot returns the latest confirmed root for a chain + algorithm.
func (k Keeper) HashRoot(goCtx context.Context, req *types.QueryHashRootRequest) (*types.QueryHashRootResponse, error) {
	if req == nil || req.ChainUid == "" || req.Algo == "" {
		return nil, status.Error(codes.InvalidArgument, "chain_uid and algo required")
	}
	r, err := k.GetHashRoot(goCtx, req.ChainUid, req.Algo)
	if err != nil {
		return nil, err
	}
	return &types.QueryHashRootResponse{Root: r}, nil
}

// HashRoots lists all confirmed roots for a chain.
func (k Keeper) HashRoots(goCtx context.Context, req *types.QueryHashRootsRequest) (*types.QueryHashRootsResponse, error) {
	if req == nil || req.ChainUid == "" {
		return nil, status.Error(codes.InvalidArgument, "chain_uid required")
	}
	var roots []types.HashRoot
	k.IterateHashRoots(goCtx, req.ChainUid, func(r types.HashRoot) bool {
		roots = append(roots, r)
		return false
	})
	return &types.QueryHashRootsResponse{Roots: roots}, nil
}

// Escrow returns the escrow record for a contract.
func (k Keeper) Escrow(goCtx context.Context, req *types.QueryEscrowRequest) (*types.QueryEscrowResponse, error) {
	if req == nil || req.ContractAddr == "" {
		return nil, status.Error(codes.InvalidArgument, "contract_addr required")
	}
	r, err := k.GetEscrowRecord(goCtx, req.ContractAddr)
	if err != nil {
		return nil, err
	}
	return &types.QueryEscrowResponse{Escrow: r}, nil
}
