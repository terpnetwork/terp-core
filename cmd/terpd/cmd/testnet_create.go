package cmd

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	cmtcfg "github.com/cometbft/cometbft/config"
	"github.com/spf13/cobra"

	"github.com/terpnetwork/terp-core/v5/app"
)

// Deterministic test mnemonics (same as localterp shell scripts).
var testMnemonics = map[string]string{
	"validator": "push certain add next grape invite tobacco bubble text romance again lava crater pill genius vital fresh guard great patch knee series era tonight",
	"a":         "grant rice replace explain federal release fix clever romance raise often wild taxi quarter soccer fiber love must tape steak together observe swap guitar",
	"b":         "jelly shadow frog dirt dragon use armed praise universe win jungle close inmate rain oil canvas beauty pioneer chef soccer icon dizzy thunder meadow",
	"c":         "chair love bleak wonder skirt permit say assist aunt credit roast size obtain minute throw sand usual age smart exact enough room shadow charge",
	"d":         "word twist toast cloth movie predict advance crumble escape whale sail such angry muffin balcony keen move employ cook valve hurt glimpse breeze brick",
}

// TestnetCmd returns the parent `testnet` command.
func TestnetCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "testnet",
		Short: "Create and manage local testnets",
		Long:  "Subcommands for creating fresh testnets, spawning faucets, and managing test infrastructure.",
	}
	cmd.AddCommand(testnetCreateCmd())
	return cmd
}

func testnetCreateCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "create",
		Short: "Create a fresh testnet and start the validator",
		Long: `Initialize a fresh single-validator testnet with pre-funded accounts and
optional embedded faucet. This replaces the localterp Docker shell scripts
with a single Go command.

If --genesis is provided, it is used directly. Otherwise a fresh genesis is
created with deterministic test keys (validator, a, b, c, d) each funded with
1e18 uterp.

The --faucet flag starts an HTTP faucet server alongside the node. The faucet
uses key "a" by default and sends tokens to any address via:
  GET /faucet?address=terp1...
  GET /status`,
		Example: `  # Fresh testnet with faucet
  terpd testnet create --chain-id zk-testnet-1 --faucet --fast-blocks

  # From existing genesis
  terpd testnet create --chain-id zk-testnet-1 --genesis /path/to/genesis.json

  # Custom faucet config
  terpd testnet create --chain-id test-1 --faucet --faucet-port 8080 --faucet-key-name b`,
		RunE: runTestnetCreate,
	}

	cmd.Flags().String("chain-id", "testnet-1", "Chain ID for the testnet")
	cmd.Flags().String("genesis", "", "Path to existing genesis file (skip init if set)")
	cmd.Flags().String("moniker", "testnet-validator", "Validator moniker")
	cmd.Flags().Bool("faucet", false, "Start embedded faucet server")
	cmd.Flags().Int("faucet-port", 5000, "Faucet HTTP port")
	cmd.Flags().String("faucet-amount", "1000000000", "Amount per faucet request (per denom)")
	cmd.Flags().String("faucet-denoms", "uterp,uthiol", "Comma-separated denoms to send")
	cmd.Flags().String("faucet-key-name", "a", "Keyring key name for faucet")
	cmd.Flags().Bool("fast-blocks", false, "Set 200ms block timeouts")
	cmd.Flags().String("home", app.DefaultNodeHome, "Node home directory")
	cmd.Flags().String("log-level", "info", "Log level for the node")

	return cmd
}

func runTestnetCreate(cmd *cobra.Command, args []string) error {
	home, _ := cmd.Flags().GetString("home")
	chainID, _ := cmd.Flags().GetString("chain-id")
	moniker, _ := cmd.Flags().GetString("moniker")
	genesisPath, _ := cmd.Flags().GetString("genesis")
	fastBlocks, _ := cmd.Flags().GetBool("fast-blocks")
	faucetEnabled, _ := cmd.Flags().GetBool("faucet")
	faucetPort, _ := cmd.Flags().GetInt("faucet-port")
	faucetAmount, _ := cmd.Flags().GetString("faucet-amount")
	faucetDenoms, _ := cmd.Flags().GetString("faucet-denoms")
	faucetKeyName, _ := cmd.Flags().GetString("faucet-key-name")
	logLevel, _ := cmd.Flags().GetString("log-level")

	fmt.Printf("=== Terp Testnet Create ===\n")
	fmt.Printf("  Home:        %s\n", home)
	fmt.Printf("  Chain ID:    %s\n", chainID)
	fmt.Printf("  Moniker:     %s\n", moniker)
	fmt.Printf("  Fast blocks: %v\n", fastBlocks)
	fmt.Printf("  Faucet:      %v\n", faucetEnabled)

	// Step 1: Initialize chain or use provided genesis
	if genesisPath != "" {
		fmt.Printf("  Using provided genesis: %s\n", genesisPath)
		if err := initFromGenesis(home, chainID, moniker, genesisPath); err != nil {
			return fmt.Errorf("init from genesis: %w", err)
		}
	} else {
		fmt.Println("  Initializing fresh chain...")
		if err := initFreshChain(home, chainID, moniker); err != nil {
			return fmt.Errorf("init fresh chain: %w", err)
		}
	}

	// Step 2: Apply fast blocks if requested
	if fastBlocks {
		cmtCfg, err := loadCometConfig(home)
		if err != nil {
			return fmt.Errorf("load config: %w", err)
		}
		applyFastBlocks(cmtCfg)
		cmtcfg.WriteConfigFile(filepath.Join(home, "config", "config.toml"), cmtCfg)
		fmt.Println("  Applied fast block settings (200ms)")
	}

	// Step 3: Apply testnet config tweaks (LCD, CORS, subscriptions)
	if err := applyTestnetConfigTweaks(home); err != nil {
		return fmt.Errorf("config tweaks: %w", err)
	}

	// Step 4: Start faucet goroutine if enabled
	if faucetEnabled {
		denoms := strings.Split(faucetDenoms, ",")
		cfg := FaucetConfig{
			Port:    faucetPort,
			Amount:  faucetAmount,
			Denoms:  denoms,
			KeyName: faucetKeyName,
			Home:    home,
			ChainID: chainID,
		}
		go func() {
			if err := runFaucetServer(cfg); err != nil {
				fmt.Fprintf(os.Stderr, "[faucet] error: %v\n", err)
			}
		}()
		fmt.Printf("  Faucet will start on :%d (key: %s)\n", faucetPort, faucetKeyName)
	}

	// Step 5: Start the node in-process via rootCmd
	fmt.Println("\n  Starting node...")
	rootCmd := cmd.Root()
	startArgs := []string{
		"start",
		"--home", home,
		"--rpc.laddr", "tcp://0.0.0.0:26657",
		"--log_level", logLevel,
	}
	rootCmd.SetArgs(startArgs)
	return rootCmd.Execute()
}

// initFreshChain creates a new chain from scratch with deterministic test keys.
func initFreshChain(home, chainID, moniker string) error {
	// Clean slate
	os.RemoveAll(home)

	// terpd init
	if err := runInit(home, moniker, chainID); err != nil {
		return fmt.Errorf("init: %w", err)
	}

	// Recover test keys via terpd keys add --recover
	for name, mnemonic := range testMnemonics {
		if err := recoverKeyCmd(home, name, mnemonic); err != nil {
			return fmt.Errorf("recover key %s: %w", name, err)
		}
		fmt.Printf("    Key recovered: %s\n", name)
	}

	// Modify genesis
	genesisFile := filepath.Join(home, "config", "genesis.json")
	if err := modifyGenesis(genesisFile, chainID); err != nil {
		return fmt.Errorf("modify genesis: %w", err)
	}

	// Add genesis accounts
	ico := "1000000000000000000"
	for name := range testMnemonics {
		if err := addGenesisAccount(home, name, ico+"uterp"); err != nil {
			return fmt.Errorf("add genesis account %s: %w", name, err)
		}
	}

	// Generate validator gentx
	if err := runCmdKeyring(home, "genesis", "gentx", "validator", ico+"uterp", "--chain-id", chainID, "--ip", "0.0.0.0"); err != nil {
		return fmt.Errorf("gentx: %w", err)
	}

	// Collect gentxs
	if err := runCmd(home, "genesis", "collect-gentxs"); err != nil {
		return fmt.Errorf("collect-gentxs: %w", err)
	}

	// Validate
	if err := runCmd(home, "genesis", "validate-genesis"); err != nil {
		return fmt.Errorf("validate-genesis: %w", err)
	}

	fmt.Println("    Genesis created and validated")
	return nil
}

// initFromGenesis initializes the node identity and copies the provided genesis.
func initFromGenesis(home, chainID, moniker, genesisPath string) error {
	genesisFile := filepath.Join(home, "config", "genesis.json")

	// Init node if not already initialized
	if _, err := os.Stat(genesisFile); os.IsNotExist(err) {
		if err := runInit(home, moniker, chainID); err != nil {
			return err
		}
	}

	// Copy provided genesis
	data, err := os.ReadFile(genesisPath)
	if err != nil {
		return fmt.Errorf("read genesis: %w", err)
	}

	// Handle JSON-RPC wrapper from CometBFT /genesis endpoint
	var wrapper struct {
		Result struct {
			Genesis json.RawMessage `json:"genesis"`
		} `json:"result"`
	}
	if json.Unmarshal(data, &wrapper) == nil && len(wrapper.Result.Genesis) > 0 {
		data = wrapper.Result.Genesis
		fmt.Println("    Unwrapped JSON-RPC genesis envelope")
	}

	if err := os.WriteFile(genesisFile, data, 0644); err != nil {
		return fmt.Errorf("write genesis: %w", err)
	}

	// Recover test keys for faucet usage
	for name, mnemonic := range testMnemonics {
		_ = recoverKeyCmd(home, name, mnemonic)
	}

	return nil
}

// modifyGenesis applies testnet-specific genesis modifications.
func modifyGenesis(genesisFile, chainID string) error {
	data, err := os.ReadFile(genesisFile)
	if err != nil {
		return err
	}

	var genesis map[string]interface{}
	if err := json.Unmarshal(data, &genesis); err != nil {
		return err
	}

	appState, ok := genesis["app_state"].(map[string]interface{})
	if !ok {
		return fmt.Errorf("missing app_state")
	}

	// Staking: bond_denom = uterp, unbonding_time = 90s
	if staking, ok := appState["staking"].(map[string]interface{}); ok {
		if params, ok := staking["params"].(map[string]interface{}); ok {
			params["bond_denom"] = "uterp"
			params["unbonding_time"] = "90s"
		}
	}

	// Mint: mint_denom = uterp
	if mint, ok := appState["mint"].(map[string]interface{}); ok {
		if params, ok := mint["params"].(map[string]interface{}); ok {
			params["mint_denom"] = "uterp"
		}
	}

	// Gov: voting_period = 90s, denoms = uterp
	if gov, ok := appState["gov"].(map[string]interface{}); ok {
		if params, ok := gov["params"].(map[string]interface{}); ok {
			params["voting_period"] = "90s"
			params["expedited_voting_period"] = "15s"
			// Fix min_deposit denoms
			if minDep, ok := params["min_deposit"].([]interface{}); ok && len(minDep) > 0 {
				if dep, ok := minDep[0].(map[string]interface{}); ok {
					dep["denom"] = "uterp"
				}
			}
			if expDep, ok := params["expedited_min_deposit"].([]interface{}); ok && len(expDep) > 0 {
				if dep, ok := expDep[0].(map[string]interface{}); ok {
					dep["denom"] = "uterp"
				}
			}
		}
		// Also fix deposit_params for older SDK format
		if dp, ok := gov["deposit_params"].(map[string]interface{}); ok {
			if minDep, ok := dp["min_deposit"].([]interface{}); ok && len(minDep) > 0 {
				if dep, ok := minDep[0].(map[string]interface{}); ok {
					dep["denom"] = "uterp"
				}
			}
		}
	}

	out, err := json.MarshalIndent(genesis, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(genesisFile, out, 0644)
}

// applyFastBlocks sets all consensus timeouts to 200ms.
func applyFastBlocks(cfg *cmtcfg.Config) {
	d := 200 * cmtcfg.DefaultConfig().Consensus.TimeoutPropose / cmtcfg.DefaultConfig().Consensus.TimeoutPropose
	_ = d
	cfg.Consensus.TimeoutPropose = 200 * 1e6     // 200ms in nanoseconds
	cfg.Consensus.TimeoutPrevote = 200 * 1e6
	cfg.Consensus.TimeoutPrecommit = 200 * 1e6
	cfg.Consensus.TimeoutCommit = 200 * 1e6
	cfg.Consensus.TimeoutProposeDelta = 0
	cfg.Consensus.TimeoutPrevoteDelta = 0
	cfg.Consensus.TimeoutPrecommitDelta = 0
}

// applyTestnetConfigTweaks configures LCD, CORS, and subscription limits.
func applyTestnetConfigTweaks(home string) error {
	// CometBFT config: open RPC to all interfaces, increase subscription limits
	cmtCfg, err := loadCometConfig(home)
	if err != nil {
		return err
	}
	cmtCfg.RPC.ListenAddress = "tcp://0.0.0.0:26657"
	cmtCfg.P2P.ListenAddress = "tcp://0.0.0.0:26656"
	cmtCfg.RPC.MaxSubscriptionClients = 100
	cmtCfg.RPC.MaxSubscriptionsPerClient = 50
	cmtcfg.WriteConfigFile(filepath.Join(home, "config", "config.toml"), cmtCfg)

	// App config: enable CORS, bind API to all interfaces
	appCfgPath := filepath.Join(home, "config", "app.toml")
	data, err := os.ReadFile(appCfgPath)
	if err != nil {
		return err
	}
	content := string(data)
	content = strings.ReplaceAll(content, `enable-unsafe-cors = false`, `enable-unsafe-cors = true`)
	content = strings.ReplaceAll(content, `enabled-unsafe-cors = false`, `enabled-unsafe-cors = true`)
	// Bind API to all interfaces
	content = strings.ReplaceAll(content, `address = "tcp://localhost:1317"`, `address = "tcp://0.0.0.0:1317"`)
	return os.WriteFile(appCfgPath, []byte(content), 0644)
}

// recoverKeyCmd recovers a key from mnemonic using terpd keys add --recover.
func recoverKeyCmd(home, name, mnemonic string) error {
	binary, err := os.Executable()
	if err != nil {
		return err
	}
	cmd := exec.Command(binary, "keys", "add", name, "--recover",
		"--home", home, "--keyring-backend", "test")
	cmd.Stdin = strings.NewReader(mnemonic + "\n")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// addGenesisAccount runs terpd genesis add-genesis-account.
func addGenesisAccount(home, name, coins string) error {
	// Resolve address from key name to avoid keyring compat issues
	binary, err := os.Executable()
	if err != nil {
		return err
	}
	out, err := exec.Command(binary, "keys", "show", name, "-a",
		"--home", home, "--keyring-backend", "test").Output()
	if err != nil {
		return fmt.Errorf("resolve key %s: %w", name, err)
	}
	addr := strings.TrimSpace(string(out))
	if addr == "" {
		return fmt.Errorf("empty address for key %s", name)
	}
	return runCmd(home, "genesis", "add-genesis-account", addr, coins)
}

// runCmd executes a terpd subcommand with --home.
func runCmd(home string, cmdArgs ...string) error {
	binary, err := os.Executable()
	if err != nil {
		return err
	}
	fullArgs := append(cmdArgs, "--home", home)
	c := exec.Command(binary, fullArgs...)
	c.Stdout = os.Stdout
	c.Stderr = os.Stderr
	return c.Run()
}

// runCmdKeyring executes a terpd subcommand with --home and --keyring-backend test.
func runCmdKeyring(home string, cmdArgs ...string) error {
	binary, err := os.Executable()
	if err != nil {
		return err
	}
	fullArgs := append(cmdArgs, "--home", home, "--keyring-backend", "test")
	c := exec.Command(binary, fullArgs...)
	c.Stdout = os.Stdout
	c.Stderr = os.Stderr
	return c.Run()
}
