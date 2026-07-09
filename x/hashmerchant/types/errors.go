package types

import errorsmod "cosmossdk.io/errors"

var (
	ErrChainNotFound         = errorsmod.Register(ModuleName, 2, "registered chain not found")
	ErrChainAlreadyExists    = errorsmod.Register(ModuleName, 3, "chain UID already registered")
	ErrContractNotFound      = errorsmod.Register(ModuleName, 4, "registered contract not found")
	ErrContractAlreadyExists = errorsmod.Register(ModuleName, 5, "contract already registered")
	ErrEscrowNotFound        = errorsmod.Register(ModuleName, 6, "escrow record not found")
	ErrInsufficientEscrow    = errorsmod.Register(ModuleName, 7, "escrow amount below minimum")
	ErrEscrowExpired         = errorsmod.Register(ModuleName, 8, "escrow has expired")
	ErrHashRootNotFound      = errorsmod.Register(ModuleName, 9, "hash root not found")
	ErrInvalidChainUID       = errorsmod.Register(ModuleName, 10, "invalid chain UID")
	ErrInvalidAlgo           = errorsmod.Register(ModuleName, 11, "unsupported hash algorithm")
	ErrQuorumNotReached      = errorsmod.Register(ModuleName, 12, "vote extension quorum not reached")
	ErrUnauthorized          = errorsmod.Register(ModuleName, 13, "unauthorized")
	ErrInvalidParams         = errorsmod.Register(ModuleName, 14, "invalid module parameters")
	ErrChainDisabled         = errorsmod.Register(ModuleName, 15, "chain is disabled")
)
