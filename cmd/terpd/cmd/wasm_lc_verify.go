package cmd

import (
	"encoding/hex"
	"fmt"
	"os"

	abci "github.com/cometbft/cometbft/abci/types"
	"github.com/cosmos/cosmos-sdk/client"
	"github.com/cosmos/cosmos-sdk/client/flags"
	ics23 "github.com/cosmos/ics23/go"
	"github.com/spf13/cobra"

	"github.com/terpnetwork/terp-core/v6/app/iavlhash"
	"github.com/terpnetwork/terp-core/v6/app/wasmlc"
)

func WasmLcVerifyCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "wasm-lc-verify",
		Short: "08-wasm Terp LC VerifyMembership of dest-bank BLAKE3 and ibc SHA-256 proofs",
		RunE: func(cmd *cobra.Command, _ []string) error {
			clientCtx, err := client.GetClientQueryContext(cmd)
			if err != nil {
				return err
			}
			wasmPath, err := cmd.Flags().GetString("wasm")
			if err != nil {
				return err
			}
			if wasmPath == "" {
				wasmPath, err = wasmlc.FindWasm()
				if err != nil {
					return err
				}
			}
			wasm, err := os.ReadFile(wasmPath)
			if err != nil {
				return err
			}
			bankStore, _ := cmd.Flags().GetString("bank-store")
			ibcStore, _ := cmd.Flags().GetString("ibc-store")

			bankM, err := membershipFromNode(clientCtx, bankStore, scanCandidates())
			if err != nil {
				return fmt.Errorf("bank %s: %w", bankStore, err)
			}
			if err := wasmlc.ExclusiveWasm(wasm, bankM); err != nil {
				return fmt.Errorf("wasm LC bank: %w", err)
			}
			ibcM, err := membershipFromNode(clientCtx, ibcStore, scanCandidates())
			if err != nil {
				return fmt.Errorf("ibc %s: %w", ibcStore, err)
			}
			if err := wasmlc.ExclusiveWasm(wasm, ibcM); err != nil {
				return fmt.Errorf("wasm LC ibc: %w", err)
			}
			fmt.Fprintf(cmd.OutOrStdout(), "OK wasm-lc bank=%s ibc=%s wasm=%s\n",
				iavlhash.AlgorithmName(bankStore), iavlhash.AlgorithmName(ibcStore), wasmPath)
			return nil
		},
	}
	flags.AddQueryFlagsToCmd(cmd)
	cmd.Flags().String("wasm", "", "path to cw_ics08_wasm_terp.wasm")
	cmd.Flags().String("bank-store", iavlhash.BankB3, "dest bank IAVL store")
	cmd.Flags().String("ibc-store", "ibc", "IBC IAVL store")
	return cmd
}

func membershipFromNode(clientCtx client.Context, store string, keys [][]byte) (wasmlc.Membership, error) {
	var last error
	for _, key := range keys {
		m, err := membershipKey(clientCtx, store, key)
		if err == nil {
			return m, nil
		}
		last = err
	}
	if last == nil {
		last = fmt.Errorf("no keys")
	}
	return wasmlc.Membership{}, last
}

func membershipKey(clientCtx client.Context, store string, key []byte) (wasmlc.Membership, error) {
	res, err := clientCtx.QueryABCI(abci.RequestQuery{
		Path:  "store/" + store + "/key",
		Data:  key,
		Prove: true,
	})
	if err != nil {
		return wasmlc.Membership{}, err
	}
	if len(res.Value) == 0 {
		return wasmlc.Membership{}, fmt.Errorf("empty value key=%s", hex.EncodeToString(key))
	}
	if res.ProofOps == nil || len(res.ProofOps.Ops) == 0 {
		return wasmlc.Membership{}, fmt.Errorf("missing proof ops")
	}
	var proofs []*ics23.CommitmentProof
	for _, op := range res.ProofOps.Ops {
		p := &ics23.CommitmentProof{}
		if err := p.Unmarshal(op.Data); err != nil {
			return wasmlc.Membership{}, err
		}
		proofs = append(proofs, p)
	}
	if proofs[0].GetExist() == nil {
		return wasmlc.Membership{}, fmt.Errorf("missing IAVL existence proof")
	}
	// Prefer chained inclusion against the app hash (IAVL + simple merkle),
	// which is the 08-wasm VerifyMembership path on a counterparty. Fall
	// back to single-layer IAVL root when ABCI only returned one ProofOp.
	root, used := chainedRoot(proofs)
	if used == nil {
		var err error
		root, err = proofs[0].GetExist().Calculate()
		if err != nil {
			return wasmlc.Membership{}, err
		}
		used = proofs[:1]
	}
	return wasmlc.Membership{
		Store:  store,
		Key:    key,
		Value:  res.Value,
		Proofs: used,
		Root:   root,
		Height: uint64(res.Height),
	}, nil
}

func chainedRoot(proofs []*ics23.CommitmentProof) ([]byte, []*ics23.CommitmentProof) {
	if len(proofs) < 2 {
		return nil, nil
	}
	last := proofs[len(proofs)-1].GetExist()
	if last == nil {
		return nil, nil
	}
	root, err := last.Calculate()
	if err != nil {
		return nil, nil
	}
	return root, proofs
}
