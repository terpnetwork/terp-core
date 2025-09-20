package cli

import (
	"encoding/base64"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"

	"github.com/cosmos/cosmos-sdk/client"
	sdk "github.com/cosmos/cosmos-sdk/types"

	"github.com/terpnetwork/terp-core/v5/terputils/terpcli"
	"github.com/terpnetwork/terp-core/v5/x/smart-account/types"
)

func NewTxCmd() *cobra.Command {
	txCmd := terpcli.TxIndexCmd(types.ModuleName)
	terpcli.AddTxCmd(txCmd, NewAddAuthentiactorCmd)
	terpcli.AddTxCmd(txCmd, NewRemoveAuthentiactorCmd)
	return txCmd
}

func NewAddAuthentiactorCmd() (*terpcli.TxCliDesc, *types.MsgAddAuthenticator) {
	return &terpcli.TxCliDesc{
		Use:   "add-authenticator",
		Short: "add an authenticator for an address",
		Long:  "",
		Example: `
			osmosisd tx authenticator add-authenticator SigVerification <pubkey> --from val \
			--chain-id osmosis-1 -b sync --keyring-backend test \
			--fees 1000uosmo
		`,
		ParseAndBuildMsg: BuildAddAuthenticatorMsg,
	}, &types.MsgAddAuthenticator{}
}

func NewRemoveAuthentiactorCmd() (*terpcli.TxCliDesc, *types.MsgRemoveAuthenticator) {
	return &terpcli.TxCliDesc{
		Use:   "remove-authenticator",
		Short: "add an authenticator for an address",
		Long:  "",
		Example: `
			osmosisd tx authenticator remove-authenticator 1 --from val \
			--chain-id osmosis-1 -b sync --keyring-backend test \
			--fees 1000uosmo
		`,
	}, &types.MsgRemoveAuthenticator{}
}

func BuildAddAuthenticatorMsg(
	clientCtx client.Context,
	args []string,
	flags *pflag.FlagSet,
) (sdk.Msg, error) {
	authenticatorType := args[0]
	pubKeyEncoded := args[1]

	pubKeyBytes, err := base64.StdEncoding.DecodeString(pubKeyEncoded)
	if err != nil {
		return nil, err
	}

	return &types.MsgAddAuthenticator{
		AuthenticatorType: authenticatorType,
		Data:              pubKeyBytes,
		Sender:            clientCtx.GetFromAddress().String(),
	}, nil
}
