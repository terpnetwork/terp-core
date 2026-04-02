package cli

import (
	"fmt"
	"strings"

	"github.com/cosmos/cosmos-sdk/client"
	"github.com/cosmos/cosmos-sdk/client/flags"
	"github.com/cosmos/cosmos-sdk/client/tx"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/spf13/cobra"

	"github.com/terpnetwork/terp-core/v5/x/hashmerchant/types"
)

func GetTxCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:                        types.ModuleName,
		Short:                      fmt.Sprintf("Transaction commands for the %s module", types.ModuleName),
		DisableFlagParsing:         true,
		SuggestionsMinimumDistance: 2,
		RunE:                       client.ValidateCmd,
	}
	cmd.AddCommand(
		CmdRegisterContract(),
		CmdRefillEscrow(),
	)
	return cmd
}

func CmdRegisterContract() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "register-contract [contract-addr] [chain-uid] [substore-keys] [escrow-amount]",
		Short: "Register a CosmWasm contract for hash-root sudo callbacks",
		Long: `Register a contract to receive sudo callbacks when new hash roots are
confirmed for the specified chain. Requires an escrow deposit.
substore-keys is a comma-separated list (e.g. "bank,staking").`,
		Args: cobra.ExactArgs(4),
		RunE: func(cmd *cobra.Command, args []string) error {
			clientCtx, err := client.GetClientTxContext(cmd)
			if err != nil {
				return err
			}
			escrow, err := sdk.ParseCoinNormalized(args[3])
			if err != nil {
				return fmt.Errorf("invalid escrow amount: %w", err)
			}
			substoreKeys := strings.Split(args[2], ",")
			msg := &types.MsgRegisterContract{
				Sender:       clientCtx.GetFromAddress().String(),
				ContractAddr: args[0],
				ChainUid:     args[1],
				SubstoreKeys: substoreKeys,
				Escrow:       escrow,
			}
			return tx.GenerateOrBroadcastTxCLI(clientCtx, cmd.Flags(), msg)
		},
	}
	flags.AddTxFlagsToCmd(cmd)
	return cmd
}

func CmdRefillEscrow() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "refill-escrow [contract-addr] [amount]",
		Short: "Refill escrow for a registered contract",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			clientCtx, err := client.GetClientTxContext(cmd)
			if err != nil {
				return err
			}
			amount, err := sdk.ParseCoinNormalized(args[1])
			if err != nil {
				return fmt.Errorf("invalid amount: %w", err)
			}
			msg := &types.MsgRefillEscrow{
				Sender:       clientCtx.GetFromAddress().String(),
				ContractAddr: args[0],
				Amount:       amount,
			}
			return tx.GenerateOrBroadcastTxCLI(clientCtx, cmd.Flags(), msg)
		},
	}
	flags.AddTxFlagsToCmd(cmd)
	return cmd
}
