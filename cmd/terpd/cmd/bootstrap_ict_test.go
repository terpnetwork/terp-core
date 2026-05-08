//go:build ict

package cmd

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	cmtcfg "github.com/cometbft/cometbft/config"
	rpchttp "github.com/cometbft/cometbft/rpc/client/http"
	"github.com/stretchr/testify/require"
)

// TestProductionRPCConnectivity verifies we can reach the production RPC,
// fetch trust info, and discover peers. Quick sanity check.
func TestProductionRPCConnectivity(t *testing.T) {
	bsCfg := DefaultBootstrapConfig()
	rpcs := splitTrimmed(bsCfg.StateSyncRPCs, ",")
	require.NotEmpty(t, rpcs, "no statesync RPCs configured in defaults")

	trustHeight, trustHash, peers, err := fetchStateSyncInfo(rpcs[0], bsCfg.TrustOffset)
	require.NoError(t, err, "failed to connect to production RPC %s", rpcs[0])
	require.True(t, trustHeight > 0, "trust height must be positive")
	require.NotEmpty(t, trustHash, "trust hash must not be empty")
	require.NotEmpty(t, peers, "must discover at least one peer")

	t.Logf("RPC          : %s", rpcs[0])
	t.Logf("Trust height : %d", trustHeight)
	t.Logf("Trust hash   : %s", trustHash)
	t.Logf("Peers found  : %d", len(peers))
}

// TestBootstrapPrivateModeConfig verifies that private mode correctly locks
// down the CometBFT P2P config.
func TestBootstrapPrivateModeConfig(t *testing.T) {
	cfg := cmtcfg.DefaultConfig()

	// Defaults should have PEX on
	require.True(t, cfg.P2P.PexReactor)
	require.True(t, cfg.Mempool.Broadcast)
	require.True(t, cfg.P2P.MaxNumInboundPeers > 0)

	applyPrivateMode(cfg)

	require.False(t, cfg.P2P.PexReactor, "PEX should be disabled")
	require.Equal(t, 0, cfg.P2P.MaxNumInboundPeers, "inbound peers should be 0")
	require.False(t, cfg.P2P.AddrBookStrict, "addr book strict should be off")
	require.Empty(t, cfg.P2P.Seeds, "seeds should be empty")
	require.False(t, cfg.Mempool.Broadcast, "mempool broadcast should be off")
}

// TestBootstrapMainnetSync is the full integration test: builds the binary,
// bootstraps a private node against mainnet, and verifies state-sync completes.
//
// Run with:
//
//	go test -tags ict -run TestBootstrapMainnetSync -timeout 10m -v ./cmd/terpd/cmd/
func TestBootstrapMainnetSync(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping mainnet sync ICT in short mode")
	}

	const (
		rpcPort = "46657"
		p2pPort = "46656"
		rpcAddr = "http://127.0.0.1:" + rpcPort
	)

	// ──── Phase 1: Build binary ────
	t.Log("Phase 1: Building terpd binary...")
	projectRoot, err := filepath.Abs(filepath.Join("..", "..", ".."))
	require.NoError(t, err)

	binPath := filepath.Join(t.TempDir(), "terpd-ict")
	buildCmd := exec.Command("go", "build", "-o", binPath, "./cmd/terpd")
	buildCmd.Dir = projectRoot
	out, err := buildCmd.CombinedOutput()
	require.NoError(t, err, "build failed:\n%s", string(out))
	t.Logf("  Binary: %s", binPath)

	// ──── Phase 2: Init + custom ports ────
	t.Log("Phase 2: Initializing node with custom ports...")
	tmpHome := t.TempDir()

	initProc := exec.Command(binPath, "init", "ict-test", "--chain-id", "morocco-1", "--home", tmpHome)
	out, err = initProc.CombinedOutput()
	require.NoError(t, err, "init failed:\n%s", string(out))

	// Set custom ports so we don't conflict with any running node
	cfg, err := loadCometConfig(tmpHome)
	require.NoError(t, err)
	cfg.P2P.ListenAddress = "tcp://0.0.0.0:" + p2pPort
	cfg.RPC.ListenAddress = "tcp://127.0.0.1:" + rpcPort
	cmtcfg.WriteConfigFile(filepath.Join(tmpHome, "config", "config.toml"), cfg)
	t.Logf("  Home: %s  (P2P=%s, RPC=%s)", tmpHome, p2pPort, rpcPort)

	// ──── Phase 3: Run bootstrap ────
	t.Log("Phase 3: Running bootstrap (private mode, state-sync to mainnet)...")

	ctx, cancel := context.WithTimeout(context.Background(), 9*time.Minute)
	defer cancel()

	bootstrapProc := exec.CommandContext(ctx, binPath, "bootstrap",
		"--home", tmpHome,
		"--chain-id", "morocco-1",
		"--moniker", "ict-test",
	)
	bootstrapProc.Stdout = os.Stdout
	bootstrapProc.Stderr = os.Stderr
	require.NoError(t, bootstrapProc.Start(), "failed to start bootstrap")

	// Track early exits
	procDone := make(chan error, 1)
	go func() {
		procDone <- bootstrapProc.Wait()
	}()
	defer func() {
		if bootstrapProc.Process != nil {
			bootstrapProc.Process.Kill()
		}
		<-procDone
	}()

	// ──── Phase 4: Monitor sync ────
	t.Log("Phase 4: Waiting for state-sync (polling every 10s)...")
	time.Sleep(20 * time.Second) // let node boot

	rpcClient, err := rpchttp.New(rpcAddr, "/websocket")
	require.NoError(t, err)

	deadline := time.After(8 * time.Minute)
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case err := <-procDone:
			t.Fatalf("bootstrap process exited unexpectedly: %v", err)

		case <-ticker.C:
			status, err := rpcClient.Status(context.Background())
			if err != nil {
				t.Log("  Node starting up...")
				continue
			}
			h := status.SyncInfo.LatestBlockHeight
			if h > 0 {
				t.Logf("  SYNCED at height %d", h)
				t.Logf("  App hash : %X", status.SyncInfo.LatestAppHash)
				t.Logf("  Network  : %s", status.NodeInfo.Network)
				t.Log("SUCCESS: Bootstrap state-sync to mainnet completed!")
				return
			}
			t.Log("  State-sync in progress...")

		case <-deadline:
			t.Fatal("state-sync did not complete within 8 minutes — peers may not have snapshots available")
		}
	}
}
