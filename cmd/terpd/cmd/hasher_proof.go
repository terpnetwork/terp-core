package cmd

import (
	"errors"
	"fmt"
	"strings"

	abci "github.com/cometbft/cometbft/abci/types"
	"github.com/cosmos/cosmos-sdk/client"
	"github.com/cosmos/cosmos-sdk/client/flags"
	banktypes "github.com/cosmos/cosmos-sdk/x/bank/types"
	ics23 "github.com/cosmos/ics23/go"
	"github.com/spf13/cobra"

	"github.com/terpnetwork/terp-core/v6/app/iavlhash"
)

var errEmptyStore = errors.New("empty store")

func HasherProofCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "hasher-proof",
		Short: "ICS-23 membership: dest IAVL BLAKE3, IBC SHA-256",
		RunE: func(cmd *cobra.Command, _ []string) error {
			clientCtx, err := client.GetClientQueryContext(cmd)
			if err != nil {
				return err
			}
			all, err := cmd.Flags().GetBool("all")
			if err != nil {
				return err
			}
			bankStore, err := cmd.Flags().GetString("bank-store")
			if err != nil {
				return err
			}
			ibcStore, err := cmd.Flags().GetString("ibc-store")
			if err != nil {
				return err
			}
			require, err := cmd.Flags().GetStringSlice("require")
			if err != nil {
				return err
			}
			if !all {
				bankAlg, err := proveStore(clientCtx, bankStore, scanCandidates())
				if err != nil {
					return fmt.Errorf("bank %s: %w", bankStore, err)
				}
				ibcAlg, err := proveStore(clientCtx, ibcStore, scanCandidates())
				if err != nil {
					return fmt.Errorf("ibc %s: %w", ibcStore, err)
				}
				fmt.Fprintf(cmd.OutOrStdout(), "OK hasher bank=%s ibc=%s\n", bankAlg, ibcAlg)
				return nil
			}
			return proveAll(cmd, clientCtx, bankStore, ibcStore, require)
		},
	}
	flags.AddQueryFlagsToCmd(cmd)
	cmd.Flags().String("bank-store", iavlhash.BankB3, "IAVL store name for bank dest")
	cmd.Flags().String("ibc-store", "ibc", "IAVL store name for IBC")
	cmd.Flags().Bool("all", false, "prove every dest store BLAKE3 and IBC SHA-256")
	cmd.Flags().StringSlice("require", []string{iavlhash.BankB3, iavlhash.StakingB3, iavlhash.AuthB3, "ibc"}, "stores that must prove (not skip empty)")
	return cmd
}

func proveAll(cmd *cobra.Command, clientCtx client.Context, bankStore, ibcStore string, require []string) error {
	need := map[string]struct{}{}
	for _, n := range require {
		n = strings.TrimSpace(n)
		if n != "" {
			need[n] = struct{}{}
		}
	}
	need[bankStore] = struct{}{}
	need[ibcStore] = struct{}{}

	var destParts []string
	proved := map[string]string{}
	for _, store := range iavlhash.DestStores() {
		alg, err := proveStore(clientCtx, store, scanCandidates())
		if errors.Is(err, errEmptyStore) {
			if _, ok := need[store]; ok {
				return fmt.Errorf("required dest %s is empty", store)
			}
			fmt.Fprintf(cmd.ErrOrStderr(), "hasher-proof: skip empty dest %s\n", store)
			continue
		}
		if err != nil {
			return fmt.Errorf("dest %s: %w", store, err)
		}
		if alg != "blake3" {
			return fmt.Errorf("dest %s: want blake3 got %s", store, alg)
		}
		proved[store] = alg
		destParts = append(destParts, store+"="+alg)
		fmt.Fprintf(cmd.OutOrStdout(), "ok  dest %s=%s\n", store, alg)
	}

	ibcNames := []string{"ibc", "transfer", "icahost", "icacontroller", "packetfowardmiddleware", "hooks-for-ibc", "08-wasm"}
	var ibcParts []string
	for _, store := range ibcNames {
		alg, err := proveStore(clientCtx, store, scanCandidates())
		if errors.Is(err, errEmptyStore) {
			if _, ok := need[store]; ok {
				return fmt.Errorf("required ibc %s is empty", store)
			}
			fmt.Fprintf(cmd.ErrOrStderr(), "hasher-proof: skip empty ibc %s\n", store)
			continue
		}
		if err != nil {
			return fmt.Errorf("ibc %s: %w", store, err)
		}
		if alg != "sha256" {
			return fmt.Errorf("ibc %s: want sha256 got %s", store, alg)
		}
		proved[store] = alg
		ibcParts = append(ibcParts, store+"="+alg)
		fmt.Fprintf(cmd.OutOrStdout(), "ok  ibc  %s=%s\n", store, alg)
	}

	for n := range need {
		if _, ok := proved[n]; !ok {
			return fmt.Errorf("required store %s did not prove", n)
		}
	}
	bankAlg := proved[bankStore]
	ibcAlg := proved[ibcStore]
	fmt.Fprintf(cmd.OutOrStdout(), "OK hasher dest %s\n", strings.Join(destParts, " "))
	fmt.Fprintf(cmd.OutOrStdout(), "OK hasher ibc-stores %s\n", strings.Join(ibcParts, " "))
	fmt.Fprintf(cmd.OutOrStdout(), "OK hasher bank=%s ibc=%s\n", bankAlg, ibcAlg)
	return nil
}

func scanCandidates() [][]byte {
	keys := [][]byte{
		banktypes.ParamsKey.Bytes(),
		[]byte("params"),
		[]byte("clientParams"),
		[]byte("nextClientSequence"),
		[]byte("connectionParams"),
	}
	for i := 0; i < 48; i++ {
		keys = append(keys, []byte{byte(i)})
	}
	return keys
}

func proveStore(clientCtx client.Context, store string, keys [][]byte) (string, error) {
	var last error
	empty := 0
	for _, key := range keys {
		alg, err := proveKey(clientCtx, store, key)
		if err == nil {
			return alg, nil
		}
		if strings.Contains(err.Error(), "empty value") {
			empty++
			continue
		}
		last = err
	}
	if last != nil {
		return "", last
	}
	if empty == len(keys) {
		return "", errEmptyStore
	}
	return "", fmt.Errorf("no candidate keys")
}

func proveKey(clientCtx client.Context, store string, key []byte) (string, error) {
	res, err := clientCtx.QueryABCI(abci.RequestQuery{
		Path:  "store/" + store + "/key",
		Data:  key,
		Prove: true,
	})
	if err != nil {
		return "", err
	}
	if len(res.Value) == 0 {
		return "", fmt.Errorf("empty value for key %x", key)
	}
	if res.ProofOps == nil || len(res.ProofOps.Ops) == 0 {
		return "", fmt.Errorf("missing proof ops")
	}
	proof := &ics23.CommitmentProof{}
	if err := proof.Unmarshal(res.ProofOps.Ops[0].Data); err != nil {
		return "", err
	}
	hop, err := iavlhash.ProofHashOp(proof)
	if err != nil {
		return "", err
	}
	root, err := proof.GetExist().Calculate()
	if err != nil {
		return "", err
	}
	if err := iavlhash.VerifyExclusive(store, root, proof, key, res.Value); err != nil {
		return "", err
	}
	switch hop {
	case ics23.HashOp_BLAKE3:
		return "blake3", nil
	case ics23.HashOp_SHA256:
		return "sha256", nil
	default:
		return "", fmt.Errorf("unexpected HashOp %v", hop)
	}
}
