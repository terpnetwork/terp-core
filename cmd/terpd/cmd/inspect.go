package cmd

import (
	"fmt"
	"path/filepath"

	"github.com/cometbft/cometbft/config"
	"github.com/cometbft/cometbft/inspect" // ← direct import
	"github.com/spf13/cobra"
	"github.com/terpnetwork/terp-core/v5/app"
)

// InspectCmd for terpd - fully self-contained
var InspectCmd = &cobra.Command{
	Use:   "inspect",
	Short: "Run a read-only inspect server to debug CometBFT state, blocks, and snapshots",
	Long: `Starts a lightweight RPC server for inspecting:
- Block store
- State store
- Snapshot metadata.db and chunk files
- App state at specific heights

Ideal for debugging snapshot restore issues or corrupted state.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		home, _ := cmd.Flags().GetString("home")
		if home == "" {
			home = app.DefaultNodeHome
		}

		// Build config properly
		cfg := config.DefaultConfig()
		cfg.SetRoot(home)

		// Override db-dir if provided (support absolute or relative)
		if dbDir, _ := cmd.Flags().GetString("db-dir"); dbDir != "" {
			if !filepath.IsAbs(dbDir) {
				dbDir = filepath.Join(home, dbDir)
			}
			cfg.DBPath = dbDir
		}

		if backend, _ := cmd.Flags().GetString("db-backend"); backend != "" {
			cfg.DBBackend = backend
		}

		fmt.Println("✅ Using home directory :", home)
		fmt.Println("✅ Genesis file path    :", cfg.GenesisFile())
		fmt.Println("✅ DB directory         :", cfg.DBDir)
		fmt.Println("✅ DB backend           :", cfg.DBBackend)

		inspector, err := inspect.NewFromConfig(cfg)
		if err != nil {
			return err
		}

		fmt.Println("🚀 Starting inspect server on", cfg.RPC.ListenAddress)
		return inspector.Run(cmd.Context())
	},
}

func init() {
	InspectCmd.Flags().String("home", app.DefaultNodeHome, "directory for config and data")
	InspectCmd.Flags().String("db-dir", "data", "database directory")
	InspectCmd.Flags().String("db-backend", "goleveldb", "database backend")
	InspectCmd.Flags().String("rpc.laddr", "tcp://127.0.0.1:26657", "RPC listen address")
}
