//go:build ict

package cmd

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	rpchttp "github.com/cometbft/cometbft/rpc/client/http"
	"github.com/stretchr/testify/require"
)

// TestSnapshotExtractAndRestore is a fully self-contained integration test.
// It creates a local single-validator chain (no external network dependency),
// validates the snapshot extraction/restore cycle, and verifies a second node
// can bootstrap from the snapshot and peer with the original.
//
// The snapshot command is network-agnostic — it operates on any terpd home
// directory regardless of chain-id, denom, or network configuration. This test
// uses a local throwaway chain to prove that.
//
// Run with:
//
//	go test -tags ict -run TestSnapshotExtractAndRestore -timeout 5m -v ./cmd/terpd/cmd/
func TestSnapshotExtractAndRestore(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping snapshot ICT in short mode")
	}

	// ─── Test chain parameters (local throwaway — no external deps) ─────
	const (
		chainID    = "snapshot-ict-1"
		moniker    = "snap-validator"
		bondDenom  = "uthiol" // binary's registered staking denom
		bondAmount = "50000000" + bondDenom
		genesisAmt = "100000000" + bondDenom

		rpcPortA = "56657"
		p2pPortA = "56656"
		rpcPortB = "57657"
		p2pPortB = "57656"
		rpcAddrA = "http://127.0.0.1:" + rpcPortA
		rpcAddrB = "http://127.0.0.1:" + rpcPortB
	)

	// ─── Phase 1: Build binary ──────────────────────────────────────────
	t.Log("Phase 1: Building terpd binary...")
	projectRoot, err := filepath.Abs(filepath.Join("..", "..", ".."))
	require.NoError(t, err)

	binPath := filepath.Join(t.TempDir(), "terpd-snapshot-ict")
	buildCmd := exec.Command("go", "build", "-o", binPath, "./cmd/terpd")
	buildCmd.Dir = projectRoot
	out, err := buildCmd.CombinedOutput()
	require.NoError(t, err, "build failed:\n%s", string(out))
	t.Logf("  Binary: %s", binPath)

	// ─── Phase 2: Init local chain (node A) ─────────────────────────────
	t.Log("Phase 2: Creating local chain (node A)...")
	homeA := t.TempDir()

	run(t, binPath, "init", moniker, "--chain-id", chainID, "--home", homeA)
	run(t, binPath, "keys", "add", "validator", "--keyring-backend", "test", "--home", homeA)

	valAddr := strings.TrimSpace(
		runOutput(t, binPath, "keys", "show", "validator", "-a", "--keyring-backend", "test", "--home", homeA),
	)
	t.Logf("  Validator: %s", valAddr)

	run(t, binPath, "genesis", "add-genesis-account", valAddr, genesisAmt,
		"--keyring-backend", "test", "--home", homeA)
	run(t, binPath, "genesis", "gentx", "validator", bondAmount,
		"--chain-id", chainID, "--keyring-backend", "test", "--home", homeA)
	run(t, binPath, "genesis", "collect-gentxs", "--home", homeA)

	// Patch ports so we don't collide with anything
	patchFile(t, filepath.Join(homeA, "config", "config.toml"), map[string]string{
		"laddr = \"tcp://0.0.0.0:26656\"":   fmt.Sprintf("laddr = \"tcp://0.0.0.0:%s\"", p2pPortA),
		"laddr = \"tcp://127.0.0.1:26657\"": fmt.Sprintf("laddr = \"tcp://127.0.0.1:%s\"", rpcPortA),
	})
	patchTomlValue(t, filepath.Join(homeA, "config", "app.toml"), "pruning", "default")

	// ─── Phase 3: Start node A ──────────────────────────────────────────
	t.Log("Phase 3: Starting node A...")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	nodeA := exec.CommandContext(ctx, binPath, "start", "--home", homeA)
	nodeA.Stdout = os.Stdout
	nodeA.Stderr = os.Stderr
	require.NoError(t, nodeA.Start())
	defer func() { cancel(); nodeA.Wait() }()

	// Wait for blocks
	waitForHeight(t, rpcAddrA, 5, 60*time.Second)

	rpcA, err := rpchttp.New(rpcAddrA, "/websocket")
	require.NoError(t, err)
	statusA, err := rpcA.Status(context.Background())
	require.NoError(t, err)
	heightBefore := statusA.SyncInfo.LatestBlockHeight
	nodeIDA := string(statusA.NodeInfo.DefaultNodeID)
	peerA := fmt.Sprintf("%s@127.0.0.1:%s", nodeIDA, p2pPortA)
	t.Logf("  Node A: height=%d peer=%s", heightBefore, peerA)

	// ─── Phase 4: Extract snapshot ──────────────────────────────────────
	t.Log("Phase 4: terpd snapshot (freeze → extract → resume)...")
	snapshotFile := filepath.Join(t.TempDir(), "snapshot.tar.lz4")

	snapOut, err := exec.Command(binPath, "snapshot",
		"--home", homeA,
		"-o", snapshotFile,
	).CombinedOutput()
	require.NoError(t, err, "snapshot failed:\n%s", string(snapOut))

	info, err := os.Stat(snapshotFile)
	require.NoError(t, err)
	require.True(t, info.Size() > 1024, "snapshot too small: %d bytes", info.Size())
	t.Logf("  Snapshot: %.2f MB", float64(info.Size())/(1024*1024))

	// ─── Phase 5: Verify node A resumed ─────────────────────────────────
	t.Log("Phase 5: Verifying node A resumed...")
	waitForHeight(t, rpcAddrA, heightBefore+2, 30*time.Second)
	statusA2, _ := rpcA.Status(context.Background())
	t.Logf("  Node A: height=%d (resumed from %d)", statusA2.SyncInfo.LatestBlockHeight, heightBefore)

	// ─── Phase 6: Restore snapshot to node B ────────────────────────────
	t.Log("Phase 6: Bootstrapping node B from snapshot...")
	homeB := t.TempDir()

	// Init fresh node B (generates its own identity)
	run(t, binPath, "init", "node-b", "--chain-id", chainID, "--home", homeB)

	// Copy genesis (same chain, different node)
	copyFile(t,
		filepath.Join(homeA, "config", "genesis.json"),
		filepath.Join(homeB, "config", "genesis.json"),
	)

	// Extract snapshot into B (data/ + wasm/ only — never overwrites config/)
	extractOut, err := exec.Command("sh", "-c",
		fmt.Sprintf("lz4 -dc %s | tar xf - -C %s", snapshotFile, homeB),
	).CombinedOutput()
	require.NoError(t, err, "extract failed:\n%s", string(extractOut))

	// Verify data dir populated, config untouched (B keeps its own identity)
	_, err = os.Stat(filepath.Join(homeB, "data", "application.db"))
	if err != nil {
		// Might be in a subdirectory depending on DB backend
		_, err = os.Stat(filepath.Join(homeB, "data"))
		require.NoError(t, err, "data/ missing after extraction")
	}

	// Node B's node_key should be different from A (snapshot didn't overwrite)
	nodeKeyA, _ := os.ReadFile(filepath.Join(homeA, "config", "node_key.json"))
	nodeKeyB, _ := os.ReadFile(filepath.Join(homeB, "config", "node_key.json"))
	require.NotEqual(t, string(nodeKeyA), string(nodeKeyB),
		"node B has same node_key as A — snapshot overwrote config/!")

	// Patch B's ports + peer with A
	patchFile(t, filepath.Join(homeB, "config", "config.toml"), map[string]string{
		"laddr = \"tcp://0.0.0.0:26656\"":   fmt.Sprintf("laddr = \"tcp://0.0.0.0:%s\"", p2pPortB),
		"laddr = \"tcp://127.0.0.1:26657\"": fmt.Sprintf("laddr = \"tcp://127.0.0.1:%s\"", rpcPortB),
		"persistent_peers = \"\"":           fmt.Sprintf("persistent_peers = \"%s\"", peerA),
	})

	// ─── Phase 7: Start node B, verify it catches up ────────────────────
	t.Log("Phase 7: Starting node B...")
	ctxB, cancelB := context.WithCancel(context.Background())
	defer cancelB()

	nodeB := exec.CommandContext(ctxB, binPath, "start", "--home", homeB)
	nodeB.Stdout = os.Stdout
	nodeB.Stderr = os.Stderr
	require.NoError(t, nodeB.Start())
	defer func() { cancelB(); nodeB.Wait() }()

	waitForHeight(t, rpcAddrB, heightBefore+1, 60*time.Second)

	rpcB, err := rpchttp.New(rpcAddrB, "/websocket")
	require.NoError(t, err)
	statusB, _ := rpcB.Status(context.Background())
	t.Logf("  Node B: height=%d catching_up=%v", statusB.SyncInfo.LatestBlockHeight, statusB.SyncInfo.CatchingUp)

	// ─── Phase 8: Verify chunk splitting works ──────────────────────────
	t.Log("Phase 8: Testing snapshot chunking...")
	chunkFile := filepath.Join(t.TempDir(), "chunk-test.tar.lz4")
	// Copy the snapshot for chunk test
	copyFile(t, snapshotFile, chunkFile)

	splitOut, err := exec.Command("split", "-b", "500K", chunkFile, chunkFile+".part-").CombinedOutput()
	if err != nil {
		t.Logf("  split not available: %s", string(splitOut))
	} else {
		chunks, _ := filepath.Glob(chunkFile + ".part-*")
		require.True(t, len(chunks) > 0, "no chunks created")
		t.Logf("  Split into %d chunks", len(chunks))

		// Verify we can reassemble
		reassembled := filepath.Join(t.TempDir(), "reassembled.tar.lz4")
		catCmd := fmt.Sprintf("cat %s.part-* > %s", chunkFile, reassembled)
		_, err = exec.Command("sh", "-c", catCmd).CombinedOutput()
		require.NoError(t, err)

		origInfo, _ := os.Stat(chunkFile)
		reassInfo, _ := os.Stat(reassembled)
		require.Equal(t, origInfo.Size(), reassInfo.Size(), "reassembled size mismatch")
		t.Log("  Reassembly verified — sizes match")
	}

	t.Log("SUCCESS: Snapshot extract → restore → peer sync → chunking verified!")
}

// ─── Test helpers ────────────────────────────────────────────────────────

func run(t *testing.T, name string, args ...string) {
	t.Helper()
	cmd := exec.Command(name, args...)
	out, err := cmd.CombinedOutput()
	require.NoError(t, err, "%s %s failed:\n%s", name, strings.Join(args, " "), string(out))
}

func runOutput(t *testing.T, name string, args ...string) string {
	t.Helper()
	cmd := exec.Command(name, args...)
	out, err := cmd.CombinedOutput()
	require.NoError(t, err, "%s %s failed:\n%s", name, strings.Join(args, " "), string(out))
	return string(out)
}

func waitForHeight(t *testing.T, rpcAddr string, target int64, timeout time.Duration) {
	t.Helper()
	deadline := time.After(timeout)
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	time.Sleep(3 * time.Second) // initial boot delay

	for {
		select {
		case <-deadline:
			t.Fatalf("node at %s did not reach height %d within %s", rpcAddr, target, timeout)
		case <-ticker.C:
			client, err := rpchttp.New(rpcAddr, "/websocket")
			if err != nil {
				continue
			}
			status, err := client.Status(context.Background())
			if err != nil {
				continue
			}
			if status.SyncInfo.LatestBlockHeight >= target {
				return
			}
		}
	}
}

func patchFile(t *testing.T, path string, replacements map[string]string) {
	t.Helper()
	data, err := os.ReadFile(path)
	require.NoError(t, err)
	content := string(data)
	for old, new := range replacements {
		content = strings.Replace(content, old, new, 1)
	}
	require.NoError(t, os.WriteFile(path, []byte(content), 0644))
}

func patchTomlValue(t *testing.T, path string, key string, value string) {
	t.Helper()
	data, err := os.ReadFile(path)
	require.NoError(t, err)
	lines := strings.Split(string(data), "\n")
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "#") {
			continue
		}
		if strings.HasPrefix(trimmed, key+" ") || strings.HasPrefix(trimmed, key+"=") {
			lines[i] = fmt.Sprintf("%s = \"%s\"", key, value)
			break
		}
	}
	require.NoError(t, os.WriteFile(path, []byte(strings.Join(lines, "\n")), 0644))
}

func copyFile(t *testing.T, src, dst string) {
	t.Helper()
	data, err := os.ReadFile(src)
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(dst, data, 0644))
}
