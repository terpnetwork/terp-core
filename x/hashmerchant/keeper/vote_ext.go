package keeper

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"

	abci "github.com/cometbft/cometbft/abci/types"
	sdk "github.com/cosmos/cosmos-sdk/types"

	"github.com/terpnetwork/terp-core/v5/x/hashmerchant/types"
)

// ---------------------------------------------------------------------------
// Vote Extension handlers (ABCI++)
//
// These are registered on BaseApp via SetExtendVoteHandler /
// SetVerifyVoteExtensionHandler in app.go.
// ---------------------------------------------------------------------------

// sidecarResponse is the JSON structure returned by the mock sidecar's
// /vote-extension endpoint.
type sidecarResponse struct {
	ChainUID         string `json:"chain_uid"`
	Algo             string `json:"algo"`
	Root             string `json:"root"` // hex-encoded
	ForeignHeight    uint64 `json:"foreign_height"`
	ForeignBlockTime int64  `json:"foreign_block_time"`
}

// ExtendVoteHandler is called by CometBFT during the vote phase.
// When a sidecar URL is configured, it HTTP GETs the sidecar for foreign-chain
// state root data. Otherwise it returns an empty extension (backwards compatible).
func (k Keeper) ExtendVoteHandler() sdk.ExtendVoteHandler {
	return func(ctx sdk.Context, req *abci.RequestExtendVote) (*abci.ResponseExtendVote, error) {
		if k.config.SidecarURL == "" {
			return &abci.ResponseExtendVote{VoteExtension: nil}, nil
		}

		data, err := k.fetchSidecar(ctx)
		if err != nil {
			k.Logger(ctx).Warn("sidecar fetch failed, returning empty extension", "err", err)
			return &abci.ResponseExtendVote{VoteExtension: nil}, nil
		}

		bz, err := k.cdc.Marshal(data)
		if err != nil {
			k.Logger(ctx).Error("failed to marshal vote extension", "err", err)
			return &abci.ResponseExtendVote{VoteExtension: nil}, nil
		}

		return &abci.ResponseExtendVote{VoteExtension: bz}, nil
	}
}

// fetchSidecar HTTP GETs the sidecar /vote-extension endpoint and parses the
// response into a VoteExtensionHashData protobuf message.
func (k Keeper) fetchSidecar(ctx sdk.Context) (*types.VoteExtensionHashData, error) {
	client := &http.Client{Timeout: k.config.SidecarTimeout}
	resp, err := client.Get(k.config.SidecarURL + "/vote-extension")
	if err != nil {
		return nil, fmt.Errorf("sidecar HTTP GET: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("sidecar returned status %d", resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("reading sidecar response: %w", err)
	}

	var sr sidecarResponse
	if err := json.Unmarshal(body, &sr); err != nil {
		return nil, fmt.Errorf("decoding sidecar JSON: %w", err)
	}

	rootBytes, err := hex.DecodeString(sr.Root)
	if err != nil {
		return nil, fmt.Errorf("decoding root hex: %w", err)
	}

	return &types.VoteExtensionHashData{
		ChainUid:         sr.ChainUID,
		Algo:             sr.Algo,
		Root:             rootBytes,
		ForeignHeight:    sr.ForeignHeight,
		ForeignBlockTime: sr.ForeignBlockTime,
	}, nil
}

// VerifyVoteExtensionHandler validates a peer's vote extension.
func (k Keeper) VerifyVoteExtensionHandler() sdk.VerifyVoteExtensionHandler {
	return func(ctx sdk.Context, req *abci.RequestVerifyVoteExtension) (*abci.ResponseVerifyVoteExtension, error) {
		// Accept empty extensions (validator may not be running the sidecar).
		if len(req.VoteExtension) == 0 {
			return &abci.ResponseVerifyVoteExtension{
				Status: abci.ResponseVerifyVoteExtension_ACCEPT,
			}, nil
		}

		// Decode and validate structure.
		var data types.VoteExtensionHashData
		if err := k.cdc.Unmarshal(req.VoteExtension, &data); err != nil {
			// Reject malformed extensions.
			return &abci.ResponseVerifyVoteExtension{
				Status: abci.ResponseVerifyVoteExtension_REJECT,
			}, nil
		}

		// Basic validity: chain must be registered and enabled.
		if !k.HasRegisteredChain(ctx, data.ChainUid) {
			return &abci.ResponseVerifyVoteExtension{
				Status: abci.ResponseVerifyVoteExtension_REJECT,
			}, nil
		}

		return &abci.ResponseVerifyVoteExtension{
			Status: abci.ResponseVerifyVoteExtension_ACCEPT,
		}, nil
	}
}

// ---------------------------------------------------------------------------
// EndBlocker — aggregate vote extensions and dispatch sudo callbacks
// ---------------------------------------------------------------------------

// EndBlocker is called at the end of each block.  It:
//  1. Aggregates vote extension data from the current block's commit.
//  2. If quorum is reached for a (chain, algo) pair, writes the HashRoot.
//  3. Dispatches sudo callbacks to registered contracts whose escrow is active.
//  4. Runs pruning if the prune interval has elapsed.
func (k Keeper) EndBlocker(ctx sdk.Context) error {
	params, err := k.GetParams(ctx)
	if err != nil {
		return err
	}

	// --- Pruning ---
	blockHeight := uint64(ctx.BlockHeight())
	lastPrune := k.GetPruneEpoch(ctx)
	if blockHeight-lastPrune >= params.PruneInterval {
		k.pruneExpiredEscrows(ctx, blockHeight)
		k.SetPruneEpoch(ctx, blockHeight)
	}

	return nil
}

// ProcessVoteExtensions is called from PreBlocker (or a proposal handler).
// It takes raw vote extension bytes from the block commit, aggregates them
// into hash root candidates, checks quorum, writes confirmed roots, and
// dispatches sudo callbacks.
func (k Keeper) ProcessVoteExtensions(ctx sdk.Context, extCommitInfo abci.ExtendedCommitInfo) error {
	params, err := k.GetParams(ctx)
	if err != nil {
		return err
	}

	// Tally: (chainUID, algo) → list of (root, votingPower).
	type rootVote struct {
		root        []byte
		height      uint64
		blockTime   int64
		votingPower int64
	}
	type tallyKey struct {
		chainUID string
		algo     string
	}
	tally := make(map[tallyKey]map[string][]rootVote)

	var totalPower int64
	for _, vote := range extCommitInfo.Votes {
		totalPower += vote.Validator.Power

		if len(vote.VoteExtension) == 0 {
			continue
		}
		var data types.VoteExtensionHashData
		if err := k.cdc.Unmarshal(vote.VoteExtension, &data); err != nil {
			continue
		}

		key := tallyKey{chainUID: data.ChainUid, algo: data.Algo}
		rootHex := fmt.Sprintf("%x", data.Root)
		if tally[key] == nil {
			tally[key] = make(map[string][]rootVote)
		}
		tally[key][rootHex] = append(tally[key][rootHex], rootVote{
			root:        data.Root,
			height:      data.ForeignHeight,
			blockTime:   data.ForeignBlockTime,
			votingPower: vote.Validator.Power,
		})
	}

	// Check quorum for each (chain, algo) pair.
	quorumThreshold := params.QuorumFraction.MulInt64(totalPower).TruncateInt().Int64()

	for key, rootMap := range tally {
		for _, votes := range rootMap {
			var power int64
			for _, v := range votes {
				power += v.votingPower
			}
			if power < quorumThreshold {
				continue
			}
			// Quorum reached — write the root.
			representative := votes[0]
			root := types.HashRoot{
				ChainUid:         key.chainUID,
				Algo:             key.algo,
				Height:           representative.height,
				Root:             representative.root,
				AttestationCount: uint32(len(votes)),
				BlockTime:        representative.blockTime,
			}
			if err := k.SetHashRoot(ctx, root); err != nil {
				k.Logger(ctx).Error("failed to set hash root", "err", err)
				continue
			}

			// Dispatch sudo callbacks to all contracts registered for this chain.
			k.dispatchSudoCallbacks(ctx, root)

			ctx.EventManager().EmitEvent(sdk.NewEvent(
				"hashmerchant_root_confirmed",
				sdk.NewAttribute("chain_uid", key.chainUID),
				sdk.NewAttribute("algo", key.algo),
				sdk.NewAttribute("attestations", fmt.Sprintf("%d", len(votes))),
			))
		}
	}

	return nil
}

// ---------------------------------------------------------------------------
// Sudo dispatch
// ---------------------------------------------------------------------------

// HashMerchantSudoMsg is the JSON envelope sent to CosmWasm contracts via sudo.
type HashMerchantSudoMsg struct {
	HashMerchant *HashMerchantSudoPayload `json:"hash_merchant"`
}

// HashMerchantSudoPayload carries the confirmed root data.
type HashMerchantSudoPayload struct {
	ChainUID         string `json:"chain_uid"`
	Algo             string `json:"algo"`
	Height           uint64 `json:"height"`
	Root             []byte `json:"root"`
	AttestationCount uint32 `json:"attestation_count"`
	BlockTime        int64  `json:"block_time"`
}

func (k Keeper) dispatchSudoCallbacks(ctx sdk.Context, root types.HashRoot) {
	blockHeight := uint64(ctx.BlockHeight())

	k.IterateRegisteredContracts(ctx, func(c types.RegisteredContract) bool {
		if c.ChainUid != root.ChainUid || !c.Enabled {
			return false
		}

		// Check escrow is still active.
		escrow, err := k.GetEscrowRecord(ctx, c.ContractAddr)
		if err != nil || escrow.PaidUntilHeight < blockHeight {
			return false
		}

		// Build sudo message.
		sudoMsg := HashMerchantSudoMsg{
			HashMerchant: &HashMerchantSudoPayload{
				ChainUID:         root.ChainUid,
				Algo:             root.Algo,
				Height:           root.Height,
				Root:             root.Root,
				AttestationCount: root.AttestationCount,
				BlockTime:        root.BlockTime,
			},
		}
		bz, err := json.Marshal(sudoMsg)
		if err != nil {
			k.Logger(ctx).Error("marshal sudo msg", "err", err)
			return false
		}

		contractAddr, err := sdk.AccAddressFromBech32(c.ContractAddr)
		if err != nil {
			return false
		}

		if _, err := k.wasmKeeper.Sudo(ctx, contractAddr, bz); err != nil {
			k.Logger(ctx).Error("sudo callback failed",
				"contract", c.ContractAddr,
				"chain_uid", root.ChainUid,
				"err", err,
			)
		}
		return false
	})
}

// ---------------------------------------------------------------------------
// Pruning
// ---------------------------------------------------------------------------

func (k Keeper) pruneExpiredEscrows(ctx sdk.Context, currentHeight uint64) {
	var toDisable []string
	k.IterateEscrowRecords(ctx, func(r types.EscrowRecord) bool {
		if r.PaidUntilHeight < currentHeight {
			toDisable = append(toDisable, r.ContractAddr)
		}
		return false
	})
	for _, addr := range toDisable {
		contract, err := k.GetRegisteredContract(ctx, addr)
		if err != nil {
			continue
		}
		contract.Enabled = false
		_ = k.SetRegisteredContract(ctx, contract)
		k.Logger(ctx).Info("disabled contract (escrow expired)", "contract", addr)
	}
}

