package cmd

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	cmtcfg "github.com/cometbft/cometbft/config"
	rpchttp "github.com/cometbft/cometbft/rpc/client/http"
	"github.com/cosmos/cosmos-sdk/server"
	"github.com/spf13/cobra"
	"github.com/spf13/viper"

	"github.com/terpnetwork/terp-core/v5/app"
)

// BootstrapConfig holds settings for automated node bootstrapping.
// Persisted in app.toml under [bootstrap].
type BootstrapConfig struct {
	SyncMode        string `mapstructure:"sync-mode"`
	GenesisURL      string `mapstructure:"genesis-url"`
	GenesisHash     string `mapstructure:"genesis-hash"`
	SnapshotURL     string `mapstructure:"snapshot-url"`
	StateSyncRPCs   string `mapstructure:"statesync-rpcs"`
	TrustOffset     int64  `mapstructure:"trust-offset"`
	MaxRetries      int    `mapstructure:"max-retries"`
	Seeds           string `mapstructure:"seeds"`
	PersistentPeers string `mapstructure:"persistent-peers"`
	PrivateMode     bool   `mapstructure:"private-mode"`
}

// DefaultBootstrapConfig returns sensible defaults for mainnet bootstrapping.
func DefaultBootstrapConfig() BootstrapConfig {
	return BootstrapConfig{
		SyncMode:        "statesync",
		GenesisURL:      "https://raw.githubusercontent.com/terpnetwork/mainnet/main/morocco-1/genesis.json",
		GenesisHash:     "",
		SnapshotURL:     "",
		StateSyncRPCs:   "https://rpc.terp.chaintools.tech:443",
		TrustOffset:     1000,
		MaxRetries:      3,
		Seeds:           "",
		PersistentPeers: "",
		PrivateMode:     true,
	}
}

// BootstrapConfigTemplate is the TOML template appended to app.toml.
const BootstrapConfigTemplate = `
###############################################################################
###                        Bootstrap Configuration                          ###
###############################################################################

[bootstrap]

# Sync mode: "statesync" or "snapshot"
sync-mode = "{{ .Bootstrap.SyncMode }}"

# Genesis file download URL
genesis-url = "{{ .Bootstrap.GenesisURL }}"

# Expected SHA256 hash of genesis.json (empty = skip validation)
genesis-hash = "{{ .Bootstrap.GenesisHash }}"

# Snapshot tarball URL (used when sync-mode = "snapshot")
snapshot-url = "{{ .Bootstrap.SnapshotURL }}"

# State-sync RPC endpoints (comma-separated, tried in order on failure)
statesync-rpcs = "{{ .Bootstrap.StateSyncRPCs }}"

# Blocks behind latest for state-sync trust height
trust-offset = {{ .Bootstrap.TrustOffset }}

# Max RPC provider rotation retries before giving up
max-retries = {{ .Bootstrap.MaxRetries }}

# Seed nodes (comma-separated id@host:port)
seeds = "{{ .Bootstrap.Seeds }}"

# Persistent peers (comma-separated id@host:port)
persistent-peers = "{{ .Bootstrap.PersistentPeers }}"

# Private mode (default true): disables PEX gossip, rejects inbound peers,
# only connects to configured persistent peers. Ideal for local state-sync
# testing without participating in the network. Use --public to disable.
private-mode = {{ .Bootstrap.PrivateMode }}
`

// BootstrapCmd automates full node bootstrapping for Docker and manual use.
var BootstrapCmd = &cobra.Command{
	Use:   "bootstrap",
	Short: "Bootstrap and start a Terp node (init + config + sync + start)",
	Long: `Fully automated node bootstrapping for Docker entrypoints and fresh nodes.

Flow:
  1. Init node if not already initialized
  2. Download and validate genesis (known hash)
  3. Configure peers, seeds, state-sync or snapshot restore
  4. Exec into terpd start

Settings are read from app.toml [bootstrap] section and can be overridden
with flags or environment variables.

Docker usage:
  ENTRYPOINT ["terpd"]
  CMD ["bootstrap"]

Direct usage:
  terpd bootstrap
  terpd bootstrap --sync-mode snapshot --snapshot-url https://...`,
	RunE: runBootstrap,
}

func init() {
	BootstrapCmd.Flags().String("moniker", "", "node moniker (auto-generated if empty)")
	BootstrapCmd.Flags().String("chain-id", "morocco-1", "chain ID")
	BootstrapCmd.Flags().String("sync-mode", "", "override sync mode: statesync or snapshot")
	BootstrapCmd.Flags().String("genesis-url", "", "override genesis download URL")
	BootstrapCmd.Flags().String("genesis-hash", "", "override expected genesis SHA256 hash")
	BootstrapCmd.Flags().String("snapshot-url", "", "override snapshot tarball URL")
	BootstrapCmd.Flags().String("statesync-rpcs", "", "override state-sync RPC endpoints (comma-separated)")
	BootstrapCmd.Flags().Int64("trust-offset", 0, "override trust offset")
	BootstrapCmd.Flags().Int("max-retries", 0, "override max retries")
	BootstrapCmd.Flags().String("bootstrap-seeds", "", "override seed nodes")
	BootstrapCmd.Flags().String("bootstrap-peers", "", "override persistent peers")
	BootstrapCmd.Flags().Bool("public", false, "public mode: enable PEX gossip and accept inbound peers (default is private)")
}

func runBootstrap(cmd *cobra.Command, args []string) error {
	home, _ := cmd.Flags().GetString("home")
	if home == "" {
		home = app.DefaultNodeHome
	}
	moniker, _ := cmd.Flags().GetString("moniker")
	chainID, _ := cmd.Flags().GetString("chain-id")

	if moniker == "" {
		moniker = fmt.Sprintf("terp-node-%d", time.Now().Unix()%10000)
	}

	// Load bootstrap config from app.toml [bootstrap] section
	bsCfg := DefaultBootstrapConfig()
	serverCtx := server.GetServerContextFromCmd(cmd)
	if serverCtx != nil && serverCtx.Viper != nil {
		_ = serverCtx.Viper.UnmarshalKey("bootstrap", &bsCfg)
	}

	// Override with flags (only when explicitly set)
	applyBootstrapFlagOverrides(cmd, &bsCfg)

	// --public flag inverts private mode
	if isPublic, _ := cmd.Flags().GetBool("public"); isPublic {
		bsCfg.PrivateMode = false
	}

	modeStr := "private"
	if !bsCfg.PrivateMode {
		modeStr = "public"
	}

	fmt.Println("=== Terp Bootstrap ===")
	fmt.Printf("  Home     : %s\n", home)
	fmt.Printf("  Chain ID : %s\n", chainID)
	fmt.Printf("  Moniker  : %s\n", moniker)
	fmt.Printf("  Sync mode: %s\n", bsCfg.SyncMode)
	fmt.Printf("  P2P mode : %s\n\n", modeStr)

	// ──── Step 1: Init if needed ────
	genesisPath := filepath.Join(home, "config", "genesis.json")
	if _, err := os.Stat(genesisPath); os.IsNotExist(err) {
		fmt.Println("Node not initialized. Running init...")
		if err := runInit(home, moniker, chainID); err != nil {
			return err
		}
		fmt.Println("Init complete.\n")
	} else {
		fmt.Println("Node already initialized.\n")
	}

	// ──── Step 2: Genesis download + validation ────
	if bsCfg.GenesisURL != "" {
		fmt.Printf("Downloading genesis from %s\n", bsCfg.GenesisURL)
		if err := downloadFile(bsCfg.GenesisURL, genesisPath); err != nil {
			return fmt.Errorf("genesis download failed: %w", err)
		}
		fmt.Println("Genesis downloaded.")
	}

	if bsCfg.GenesisHash != "" {
		fmt.Printf("Validating genesis hash...")
		if err := validateFileHash(genesisPath, bsCfg.GenesisHash); err != nil {
			return fmt.Errorf("genesis validation failed: %w", err)
		}
		fmt.Println(" OK")
	}

	// ──── Step 3: Load and modify CometBFT config ────
	cmtCfg, err := loadCometConfig(home)
	if err != nil {
		return fmt.Errorf("failed to load config.toml: %w", err)
	}

	// Apply seeds and persistent peers from bootstrap config
	if bsCfg.Seeds != "" {
		cmtCfg.P2P.Seeds = bsCfg.Seeds
	}
	if bsCfg.PersistentPeers != "" {
		cmtCfg.P2P.PersistentPeers = bsCfg.PersistentPeers
	}

	switch bsCfg.SyncMode {
	case "statesync":
		if err := configureStateSyncBootstrap(cmtCfg, bsCfg); err != nil {
			return err
		}
	case "snapshot":
		if err := configureSnapshotBootstrap(home, cmtCfg, bsCfg); err != nil {
			return err
		}
	default:
		return fmt.Errorf("unknown sync-mode: %q (use 'statesync' or 'snapshot')", bsCfg.SyncMode)
	}

	// ──── Step 4: Apply P2P mode ────
	if bsCfg.PrivateMode {
		applyPrivateMode(cmtCfg)
		fmt.Println("Private mode: PEX disabled, inbound peers rejected, no gossip.")
	}

	// Write updated config.toml
	configTomlPath := filepath.Join(home, "config", "config.toml")
	cmtcfg.WriteConfigFile(configTomlPath, cmtCfg)
	fmt.Println("config.toml updated.\n")

	// ──── Step 5: Exec into terpd start ────
	fmt.Println("Bootstrap complete. Starting node...")
	binary, err := os.Executable()
	if err != nil {
		return fmt.Errorf("failed to resolve executable path: %w", err)
	}

	startArgs := []string{"terpd", "start", "--home", home}
	// syscall.Exec replaces current process — clean for Docker PID 1
	return syscall.Exec(binary, startArgs, os.Environ())
}

// ──── State-sync configuration ────

func configureStateSyncBootstrap(cmtCfg *cmtcfg.Config, bsCfg BootstrapConfig) error {
	rpcs := splitTrimmed(bsCfg.StateSyncRPCs, ",")
	if len(rpcs) == 0 {
		return fmt.Errorf("no statesync-rpcs configured")
	}

	var lastErr error
	for attempt := 0; attempt < bsCfg.MaxRetries; attempt++ {
		rpc := rpcs[attempt%len(rpcs)]
		fmt.Printf("Trying RPC %d/%d: %s\n", attempt+1, bsCfg.MaxRetries, rpc)

		trustHeight, trustHash, peers, err := fetchStateSyncInfo(rpc, bsCfg.TrustOffset)
		if err != nil {
			fmt.Printf("  Failed: %v\n", err)
			lastErr = err
			continue
		}

		fmt.Printf("  Trust height: %d\n", trustHeight)
		fmt.Printf("  Trust hash  : %s\n", trustHash)
		fmt.Printf("  Peers found : %d\n", len(peers))

		cmtCfg.StateSync.Enable = true
		cmtCfg.StateSync.RPCServers = []string{rpc, rpc} // >=2 required by CometBFT
		cmtCfg.StateSync.TrustHeight = trustHeight
		cmtCfg.StateSync.TrustHash = trustHash
		cmtCfg.StateSync.TrustPeriod = 168 * time.Hour

		// Merge discovered peers with any already configured
		if len(peers) > 0 {
			discovered := strings.Join(peers, ",")
			if cmtCfg.P2P.PersistentPeers != "" {
				cmtCfg.P2P.PersistentPeers += "," + discovered
			} else {
				cmtCfg.P2P.PersistentPeers = discovered
			}
		}

		fmt.Println("State-sync configured.\n")
		return nil
	}

	return fmt.Errorf("state-sync config failed after %d attempts: %w", bsCfg.MaxRetries, lastErr)
}

// ──── Snapshot configuration ────

func configureSnapshotBootstrap(home string, cmtCfg *cmtcfg.Config, bsCfg BootstrapConfig) error {
	if bsCfg.SnapshotURL == "" {
		return fmt.Errorf("snapshot-url is required when sync-mode is 'snapshot'")
	}

	dataDir := filepath.Join(home, "data")
	fmt.Printf("Downloading snapshot from %s\n", bsCfg.SnapshotURL)
	if err := downloadAndExtractTarball(bsCfg.SnapshotURL, dataDir); err != nil {
		return fmt.Errorf("snapshot restore failed: %w", err)
	}
	fmt.Println("Snapshot extracted.\n")

	// Disable state-sync — node will catch up from snapshot height via block-sync
	cmtCfg.StateSync.Enable = false

	// Still discover peers for block-sync connectivity
	rpcs := splitTrimmed(bsCfg.StateSyncRPCs, ",")
	if len(rpcs) > 0 && rpcs[0] != "" {
		_, _, peers, err := fetchStateSyncInfo(rpcs[0], bsCfg.TrustOffset)
		if err == nil && len(peers) > 0 {
			discovered := strings.Join(peers, ",")
			if cmtCfg.P2P.PersistentPeers != "" {
				cmtCfg.P2P.PersistentPeers += "," + discovered
			} else {
				cmtCfg.P2P.PersistentPeers = discovered
			}
		}
	}

	return nil
}

// ──── RPC helpers ────

// fetchStateSyncInfo queries an RPC for trust height, hash, and peer addresses.
func fetchStateSyncInfo(rpcAddr string, trustOffset int64) (int64, string, []string, error) {
	client, err := rpchttp.New(rpcAddr, "/websocket")
	if err != nil {
		return 0, "", nil, err
	}

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	status, err := client.Status(ctx)
	if err != nil {
		return 0, "", nil, fmt.Errorf("status: %w", err)
	}

	latestHeight := status.SyncInfo.LatestBlockHeight
	trustHeight := latestHeight - trustOffset
	if trustHeight < 1 {
		trustHeight = 1
	}

	block, err := client.Block(ctx, &trustHeight)
	if err != nil {
		return 0, "", nil, fmt.Errorf("block at %d: %w", trustHeight, err)
	}
	trustHash := hex.EncodeToString(block.BlockID.Hash)

	// Collect peers
	var peers []string
	rpcNodeID := string(status.NodeInfo.DefaultNodeID)
	rpcHost := extractHost(rpcAddr) // reuse helper from statesync.go
	if rpcHost != "" {
		peers = append(peers, fmt.Sprintf("%s@%s:26656", rpcNodeID, rpcHost))
	}

	netInfo, err := client.NetInfo(ctx)
	if err == nil {
		for _, p := range netInfo.Peers {
			port := "26656"
			if parts := strings.Split(p.NodeInfo.ListenAddr, ":"); len(parts) > 1 {
				port = parts[len(parts)-1]
			}
			peers = append(peers, fmt.Sprintf("%s@%s:%s", p.NodeInfo.DefaultNodeID, p.RemoteIP, port))
		}
	}

	return trustHeight, trustHash, peers, nil
}

// ──── File / download helpers ────

func runInit(home, moniker, chainID string) error {
	binary, err := os.Executable()
	if err != nil {
		return fmt.Errorf("failed to resolve executable: %w", err)
	}
	initCmd := exec.Command(binary, "init", moniker, "--chain-id", chainID, "--home", home)
	initCmd.Stdout = os.Stdout
	initCmd.Stderr = os.Stderr
	if err := initCmd.Run(); err != nil {
		return fmt.Errorf("terpd init failed: %w", err)
	}
	return nil
}

func downloadFile(url, destPath string) error {
	resp, err := http.Get(url) //nolint:gosec // URL comes from operator config
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d from %s", resp.StatusCode, url)
	}

	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	return os.WriteFile(destPath, data, 0o644)
}

func validateFileHash(path, expectedHash string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	h := sha256.Sum256(data)
	actual := hex.EncodeToString(h[:])
	if actual != expectedHash {
		return fmt.Errorf("hash mismatch: expected %s, got %s", expectedHash, actual)
	}
	return nil
}

func downloadAndExtractTarball(url, destDir string) error {
	resp, err := http.Get(url) //nolint:gosec // URL comes from operator config
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d from %s", resp.StatusCode, url)
	}

	// Stream directly into tar — supports .tar.gz
	tarCmd := exec.Command("tar", "-xzf", "-", "-C", destDir)
	tarCmd.Stdin = resp.Body
	tarCmd.Stdout = os.Stdout
	tarCmd.Stderr = os.Stderr
	return tarCmd.Run()
}

func loadCometConfig(home string) (*cmtcfg.Config, error) {
	cfg := cmtcfg.DefaultConfig()
	cfg.SetRoot(home)

	configFile := filepath.Join(home, "config", "config.toml")
	if _, err := os.Stat(configFile); err != nil {
		return cfg, nil // return defaults if config.toml doesn't exist yet
	}

	v := viper.New()
	v.SetConfigFile(configFile)
	if err := v.ReadInConfig(); err != nil {
		return nil, fmt.Errorf("reading config.toml: %w", err)
	}
	if err := v.Unmarshal(cfg); err != nil {
		return nil, fmt.Errorf("parsing config.toml: %w", err)
	}
	return cfg, nil
}

// ──── P2P mode helpers ────

// applyPrivateMode locks down P2P so the node only connects to configured
// persistent peers, rejects all inbound connections, and never gossips.
// Ideal for pulling a local state-sync without participating in the network.
func applyPrivateMode(cfg *cmtcfg.Config) {
	cfg.P2P.PexReactor = false         // no peer exchange gossip
	cfg.P2P.MaxNumInboundPeers = 0     // reject all inbound connections
	cfg.P2P.MaxNumOutboundPeers = 10   // only our configured peers
	cfg.P2P.AddrBookStrict = false     // allow non-routable addrs (local testing)
	cfg.P2P.Seeds = ""                 // no seeds — only persistent peers
	cfg.Mempool.Broadcast = false      // don't broadcast txs to peers
}

// ──── Misc helpers ────

func applyBootstrapFlagOverrides(cmd *cobra.Command, bsCfg *BootstrapConfig) {
	if v, _ := cmd.Flags().GetString("sync-mode"); v != "" {
		bsCfg.SyncMode = v
	}
	if v, _ := cmd.Flags().GetString("genesis-url"); v != "" {
		bsCfg.GenesisURL = v
	}
	if v, _ := cmd.Flags().GetString("genesis-hash"); v != "" {
		bsCfg.GenesisHash = v
	}
	if v, _ := cmd.Flags().GetString("snapshot-url"); v != "" {
		bsCfg.SnapshotURL = v
	}
	if v, _ := cmd.Flags().GetString("statesync-rpcs"); v != "" {
		bsCfg.StateSyncRPCs = v
	}
	if v, _ := cmd.Flags().GetInt64("trust-offset"); v > 0 {
		bsCfg.TrustOffset = v
	}
	if v, _ := cmd.Flags().GetInt("max-retries"); v > 0 {
		bsCfg.MaxRetries = v
	}
	if v, _ := cmd.Flags().GetString("bootstrap-seeds"); v != "" {
		bsCfg.Seeds = v
	}
	if v, _ := cmd.Flags().GetString("bootstrap-peers"); v != "" {
		bsCfg.PersistentPeers = v
	}
}

func splitTrimmed(s, sep string) []string {
	parts := strings.Split(s, sep)
	var result []string
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			result = append(result, p)
		}
	}
	return result
}
