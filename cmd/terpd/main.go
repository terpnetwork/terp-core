package main

import (
	"fmt"
	"os"

	svrcmd "github.com/cosmos/cosmos-sdk/server/cmd"

	"github.com/terpnetwork/terp-core/v6/app"
	"github.com/terpnetwork/terp-core/v6/cmd/terpd/cmd"
)

func main() {
	app.SetAddressPrefixes()
	rootCmd, _ := cmd.NewRootCmd()

	if err := svrcmd.Execute(rootCmd, "TERPD", app.DefaultNodeHome); err != nil {
		// Client commands (status, query) fail this way when no node is listening.
		// Do not wrap as "failure when running app" — that is a node-start error.
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
