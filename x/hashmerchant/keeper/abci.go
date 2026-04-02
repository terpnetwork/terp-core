package keeper

import (
	"bytes"

	abci "github.com/cometbft/cometbft/abci/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
)

// InjectedVoteExtensionPrefix is a 4-byte magic prefix prepended to the
// marshalled ExtendedCommitInfo that gets injected as the first "tx" in a
// block proposal. This lets the PreBlocker distinguish the pseudo-tx from
// real transactions.
var InjectedVoteExtensionPrefix = []byte{0x48, 0x4D, 0x56, 0x45} // "HMVE"

// PrepareProposalHandler returns a handler that aggregates non-empty vote
// extensions from LocalLastCommit and injects the marshalled ExtendedCommitInfo
// as the first tx in the proposal (prefixed with InjectedVoteExtensionPrefix).
//
// If no vote extensions are present the proposal txs are returned unchanged.
func (k Keeper) PrepareProposalHandler() sdk.PrepareProposalHandler {
	return func(ctx sdk.Context, req *abci.RequestPrepareProposal) (*abci.ResponsePrepareProposal, error) {
		// Check whether any vote carried a non-empty extension.
		var hasExtensions bool
		for _, v := range req.LocalLastCommit.Votes {
			if len(v.VoteExtension) > 0 {
				hasExtensions = true
				break
			}
		}
		if !hasExtensions {
			return &abci.ResponsePrepareProposal{Txs: req.Txs}, nil
		}

		// Marshal the full ExtendedCommitInfo (includes per-validator
		// extensions and voting power so ProcessVoteExtensions can tally).
		bz, err := req.LocalLastCommit.Marshal()
		if err != nil {
			k.Logger(ctx).Error("failed to marshal ExtendedCommitInfo", "err", err)
			return &abci.ResponsePrepareProposal{Txs: req.Txs}, nil
		}

		injectedTx := append(InjectedVoteExtensionPrefix, bz...)

		txs := make([][]byte, 0, len(req.Txs)+1)
		txs = append(txs, injectedTx)
		txs = append(txs, req.Txs...)

		return &abci.ResponsePrepareProposal{Txs: txs}, nil
	}
}

// ProcessProposalHandler returns a handler that validates an injected vote
// extension pseudo-tx if present. All other txs are accepted as-is (the
// default baseapp behaviour already validates mempool txs).
func (k Keeper) ProcessProposalHandler() sdk.ProcessProposalHandler {
	return func(ctx sdk.Context, req *abci.RequestProcessProposal) (*abci.ResponseProcessProposal, error) {
		if len(req.Txs) == 0 {
			return &abci.ResponseProcessProposal{
				Status: abci.ResponseProcessProposal_ACCEPT,
			}, nil
		}

		// If the first tx carries our magic prefix, validate it.
		if bytes.HasPrefix(req.Txs[0], InjectedVoteExtensionPrefix) {
			data := req.Txs[0][len(InjectedVoteExtensionPrefix):]
			var commitInfo abci.ExtendedCommitInfo
			if err := commitInfo.Unmarshal(data); err != nil {
				return &abci.ResponseProcessProposal{
					Status: abci.ResponseProcessProposal_REJECT,
				}, nil
			}
		}

		return &abci.ResponseProcessProposal{
			Status: abci.ResponseProcessProposal_ACCEPT,
		}, nil
	}
}

// ProcessInjectedVoteExtension extracts and processes the vote extension
// pseudo-tx from the first position of the block's txs. Called from the
// app-level PreBlocker which has access to RequestFinalizeBlock.Txs.
//
// Returns true if a pseudo-tx was found and processed.
func (k Keeper) ProcessInjectedVoteExtension(ctx sdk.Context, txs [][]byte) bool {
	if len(txs) == 0 || !bytes.HasPrefix(txs[0], InjectedVoteExtensionPrefix) {
		return false
	}

	data := txs[0][len(InjectedVoteExtensionPrefix):]
	var commitInfo abci.ExtendedCommitInfo
	if err := commitInfo.Unmarshal(data); err != nil {
		k.Logger(ctx).Error("failed to unmarshal injected vote extension", "err", err)
		return false
	}

	if err := k.ProcessVoteExtensions(ctx, commitInfo); err != nil {
		k.Logger(ctx).Error("ProcessVoteExtensions failed", "err", err)
		return false
	}

	return true
}
