package cli

import (
	"github.com/spf13/cobra"
	"github.com/terpnetwork/terp-core/v5/terputils/terpcli"

	"github.com/terpnetwork/terp-core/v5/x/smart-account/types"
	// "github.com/terpnetwork/terp-core/v5/terputils/terpcli"
)

func GetQueryCmd() *cobra.Command {
	cmd := terpcli.QueryIndexCmd(types.ModuleName)
	terpcli.AddQueryCmd(cmd, types.NewQueryClient, GetCmdAuthenticators)
	terpcli.AddQueryCmd(cmd, types.NewQueryClient, GetCmdAuthenticator)
	terpcli.AddQueryCmd(cmd, types.NewQueryClient, GetCmdParams)

	return cmd
}

func GetCmdAuthenticators() (*terpcli.QueryDescriptor, *types.GetAuthenticatorsRequest) {
	return &terpcli.QueryDescriptor{
		Use:   "authenticators",
		Short: "Query authenticators by account",
		Long: `{{.Short}}{{.ExampleHeader}}
{{.CommandPrefix}} terp12smx2wdlyttvyzvzg54y2vnqwq2qjateuf7thj`,
	}, &types.GetAuthenticatorsRequest{}
}

func GetCmdAuthenticator() (*terpcli.QueryDescriptor, *types.GetAuthenticatorRequest) {
	return &terpcli.QueryDescriptor{
		Use:   "authenticator",
		Short: "Query authenticator by account and id",
		Long: `{{.Short}}{{.ExampleHeader}}
{{.CommandPrefix}} terp12smx2wdlyttvyzvzg54y2vnqwq2qjateuf7thj 17`,
	}, &types.GetAuthenticatorRequest{}
}

func GetCmdParams() (*terpcli.QueryDescriptor, *types.QueryParamsRequest) {
	return &terpcli.QueryDescriptor{
		Use:   "params",
		Short: "Query smartaccount params",
		Long: `{{.Short}}{{.ExampleHeader}}
{{.CommandPrefix}} params`,
	}, &types.QueryParamsRequest{}
}
