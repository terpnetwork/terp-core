package cmd

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"
	"github.com/syndtr/goleveldb/leveldb"
	"github.com/syndtr/goleveldb/leveldb/opt"
	"github.com/syndtr/goleveldb/leveldb/util"
)

func init() {
	SnapshotCmd.AddCommand(snapshotProcessCmd)
}

var snapshotProcessCmd = &cobra.Command{
	Use:   "process",
	Short: "Create pruned snapshot variants from a full snapshot archive",
	Long: `Generate multiple snapshot tiers from a single full snapshot archive.

This command automates the entire pruning pipeline:
  1. Creates a temporary terpd home directory
  2. Restores the input snapshot (data/ + wasm/)
  3. Initializes node config (genesis, chain-id)
  4. Starts terpd with the target pruning strategy
  5. Waits for the node to open the DB and apply pruning compaction
  6. Stops the node, extracts the pruned data as a new snapshot
  7. Cleans up the temporary home

By default, produces three tiers:
  full        — original data, no pruning applied (recompressed only)
  pruned      — pruning=default (keeps last 362880 states)
  minimal     — pruning=everything (keeps last 2 states)
  sentry      — pruning=everything + excludes blockstore.db and state.db

The "sentry" tier is optimized for deploying sentry/RPC nodes: it contains
only the pruned application state, wasm, and tx_index. Nodes restore the
snapshot and then run "terpd comet bootstrap-state" to reconstruct the
CometBFT state via light client before starting. This produces the smallest
possible snapshot (~1-2 GB vs 9+ GB for full).

The "terpd bootstrap" command handles this automatically when it detects a
sentry snapshot (missing blockstore.db/state.db).

Examples:
  # Generate a sentry-optimized snapshot (~1-2 GB)
  terpd snapshot process --input /tmp/full-snapshot.tar.lz4 \
    --output-dir /tmp/snapshots --tiers sentry \
    --chain-id morocco-1 \
    --genesis-url https://raw.githubusercontent.com/.../genesis.json

  # Generate all tiers including sentry
  terpd snapshot process --input /tmp/full-snapshot.tar.lz4 \
    --output-dir /tmp/snapshots --tiers full,sentry \
    --chain-id morocco-1 \
    --genesis-url https://raw.githubusercontent.com/.../genesis.json

  # Just recompress to zstd without pruning (offline, no node start)
  terpd snapshot process --input /tmp/snapshot.tar.lz4 \
    --output-dir /tmp/snapshots --tiers full

  # Custom tier selection
  terpd snapshot process --input /tmp/snapshot.tar.lz4 \
    --output-dir /tmp/snapshots --tiers pruned,minimal \
    --chain-id morocco-1 \
    --genesis-url https://raw.githubusercontent.com/.../genesis.json`,
	RunE: runSnapshotProcess,
}

func init() {
	f := snapshotProcessCmd.Flags()
	f.String("input", "", "input snapshot archive (required)")
	f.String("output-dir", ".", "directory to write output snapshots")
	f.String("format", "zst", "output compression: lz4, zst, gz")
	f.String("tiers", "full,pruned,minimal", "comma-separated tiers to generate")
	f.String("chain-id", "morocco-1", "chain ID for node init")
	f.String("genesis-url", "", "genesis JSON URL (required for pruned/minimal tiers)")
	f.String("peers", "", "persistent peers for the temp node (optional, helps compaction)")
	f.Int("compact-blocks", 10, "number of blocks to wait during compaction before extracting")
	f.Int("compact-timeout", 120, "max seconds to wait for compaction")
	snapshotProcessCmd.MarkFlagRequired("input")
}

type snapshotTier struct {
	name       string
	pruning    string // "nothing", "default", "everything"
	excludeDBs []string // DB dirs to exclude from archive (e.g. blockstore.db, state.db)
}

var tierDefs = map[string]snapshotTier{
	"full":    {name: "full", pruning: "nothing"},
	"pruned":  {name: "pruned", pruning: "default"},
	"minimal": {name: "minimal", pruning: "everything"},
	"sentry": {
		name:       "sentry",
		pruning:    "everything",
		excludeDBs: []string{"blockstore.db", "state.db"},
	},
}

func runSnapshotProcess(cmd *cobra.Command, args []string) error {
	input, _ := cmd.Flags().GetString("input")
	outputDir, _ := cmd.Flags().GetString("output-dir")
	format, _ := cmd.Flags().GetString("format")
	tiersStr, _ := cmd.Flags().GetString("tiers")
	chainID, _ := cmd.Flags().GetString("chain-id")
	genesisURL, _ := cmd.Flags().GetString("genesis-url")
	peers, _ := cmd.Flags().GetString("peers")
	compactBlocks, _ := cmd.Flags().GetInt("compact-blocks")
	compactTimeout, _ := cmd.Flags().GetInt("compact-timeout")

	// Validate input exists
	if _, err := os.Stat(input); err != nil {
		return fmt.Errorf("input snapshot not found: %s", input)
	}

	// Parse requested tiers
	tierNames := strings.Split(tiersStr, ",")
	var tiers []snapshotTier
	needsNode := false
	for _, name := range tierNames {
		name = strings.TrimSpace(name)
		t, ok := tierDefs[name]
		if !ok {
			return fmt.Errorf("unknown tier %q — use full, pruned, minimal, or sentry", name)
		}
		tiers = append(tiers, t)
		if name != "full" {
			needsNode = true
		}
	}

	if needsNode && genesisURL == "" {
		return fmt.Errorf("--genesis-url is required for pruned/minimal tiers (node must start)")
	}

	// Create output dir
	if err := os.MkdirAll(outputDir, 0755); err != nil {
		return fmt.Errorf("cannot create output dir: %w", err)
	}

	// Detect input compression
	inputFormat := detectFormat(input)
	fmt.Printf("Input:   %s (%s)\n", input, inputFormat)
	fmt.Printf("Output:  %s (format: %s)\n", outputDir, format)
	fmt.Printf("Tiers:   %s\n", tiersStr)

	// Find our own binary path for spawning temp nodes
	binary, err := os.Executable()
	if err != nil {
		binary = "terpd"
	}

	for _, tier := range tiers {
		fmt.Printf("\n═══ Tier: %s (pruning=%s) ═══\n", tier.name, tier.pruning)

		outFile := filepath.Join(outputDir, fmt.Sprintf("terp-snapshot-%s.tar.%s", tier.name, format))

		if tier.name == "full" {
			// Full tier: just recompress, no node needed
			if err := recompressSnapshot(input, inputFormat, outFile, format); err != nil {
				return fmt.Errorf("full tier failed: %w", err)
			}
		} else {
			// Pruned tiers: restore → start node → compact → extract
			if err := processPrunedTier(binary, input, inputFormat, outFile, format,
				tier, chainID, genesisURL, peers, compactBlocks, compactTimeout); err != nil {
				return fmt.Errorf("%s tier failed: %w", tier.name, err)
			}
		}

		info, _ := os.Stat(outFile)
		if info != nil {
			fmt.Printf("  Output: %s (%.2f GB)\n", outFile, float64(info.Size())/(1024*1024*1024))
		}
	}

	fmt.Println("\nAll tiers complete.")
	return nil
}

// recompressSnapshot converts between compression formats without starting a node.
func recompressSnapshot(input, inputFmt, output, outputFmt string) error {
	fmt.Println("  Recompressing (no node needed)...")

	if inputFmt == outputFmt {
		// Same format — just copy
		fmt.Println("  Same format — copying...")
		cpCmd := exec.Command("cp", input, output)
		return cpCmd.Run()
	}

	// Decompress → recompress
	decompressor := decompressCmd(inputFmt, input)
	if decompressor == nil {
		return fmt.Errorf("cannot decompress %s format", inputFmt)
	}

	outFile, err := os.Create(output)
	if err != nil {
		return err
	}
	defer outFile.Close()

	compressor := compressCmd(outputFmt)
	if compressor == nil {
		return fmt.Errorf("cannot compress to %s format", outputFmt)
	}

	pipe, err := decompressor.StdoutPipe()
	if err != nil {
		return err
	}
	compressor.Stdin = pipe
	compressor.Stdout = outFile

	if err := decompressor.Start(); err != nil {
		return err
	}
	if err := compressor.Start(); err != nil {
		return err
	}

	compErr := compressor.Wait()
	decErr := decompressor.Wait()
	if decErr != nil {
		return decErr
	}
	return compErr
}

// processPrunedTier handles the full lifecycle: temp home → restore → prune → compact → extract.
func processPrunedTier(binary, input, inputFmt, output, outputFmt string,
	tier snapshotTier, chainID, genesisURL, _ string,
	_, _ int) error {

	// Create isolated temp home
	tmpHome, err := os.MkdirTemp("", fmt.Sprintf("terpd-snapshot-%s-", tier.name))
	if err != nil {
		return fmt.Errorf("cannot create temp dir: %w", err)
	}
	defer func() {
		fmt.Printf("  Cleaning up %s...\n", tmpHome)
		os.RemoveAll(tmpHome)
	}()
	fmt.Printf("  Temp home: %s\n", tmpHome)

	// Step 1: Init node (creates config/ with fresh identity)
	fmt.Println("  Initializing temp node...")
	initCmd := exec.Command(binary, "init", fmt.Sprintf("snapshot-%s", tier.name),
		"--chain-id", chainID, "--home", tmpHome)
	if out, err := initCmd.CombinedOutput(); err != nil {
		return fmt.Errorf("init failed: %w\n%s", err, string(out))
	}

	// Step 2: Download genesis
	fmt.Println("  Downloading genesis...")
	genesisPath := filepath.Join(tmpHome, "config", "genesis.json")
	dlCmd := exec.Command("wget", "-q", "-O", genesisPath, genesisURL)
	if out, err := dlCmd.CombinedOutput(); err != nil {
		// Try curl as fallback
		dlCmd = exec.Command("curl", "-fsSL", "-o", genesisPath, genesisURL)
		if out, err = dlCmd.CombinedOutput(); err != nil {
			return fmt.Errorf("genesis download failed: %w\n%s", err, string(out))
		}
	}

	// Step 3: Restore snapshot data into temp home
	fmt.Println("  Restoring snapshot data...")
	if err := extractToHome(input, inputFmt, tmpHome); err != nil {
		return fmt.Errorf("snapshot restore failed: %w", err)
	}

	// Step 4: Bulk-prune historical state offline using `terpd prune`.
	// This deletes all versions except the most recent in a single pass
	// without needing to start a node or sync blocks.
	fmt.Printf("  Bulk-pruning state (strategy: %s)...\n", tier.pruning)
	pruneCmd := exec.Command(binary, "prune", tier.pruning, "--home", tmpHome)
	pruneCmd.Stdout = os.Stderr
	pruneCmd.Stderr = os.Stderr
	if err := pruneCmd.Run(); err != nil {
		return fmt.Errorf("prune failed: %w", err)
	}
	fmt.Println("  Prune complete.")

	// Step 5: Force-compact every LevelDB in data/ to reclaim space from
	// pruned tombstones. Without this, deleted keys remain as tombstones
	// in SST files and disk usage barely changes.
	fmt.Println("  Compacting LevelDB databases...")
	dataDir := filepath.Join(tmpHome, "data")
	if err := compactAllLevelDBs(dataDir); err != nil {
		fmt.Printf("  Warning: compaction had errors: %v\n", err)
	}

	// Step 6: Remove excluded DBs (sentry tier strips blockstore + state)
	if len(tier.excludeDBs) > 0 {
		dataDir := filepath.Join(tmpHome, "data")
		for _, dbName := range tier.excludeDBs {
			dbPath := filepath.Join(dataDir, dbName)
			if _, err := os.Stat(dbPath); err == nil {
				before := dirSize(dbPath)
				os.RemoveAll(dbPath)
				fmt.Printf("    Excluded %s (%.2f GB)\n", dbName, float64(before)/(1024*1024*1024))
			}
		}
	}

	// Step 7: Archive remaining data
	extractDirs := []string{"data"}
	for _, extra := range []string{"wasm", "ibc_08-wasm"} {
		if _, err := os.Stat(filepath.Join(tmpHome, extra)); err == nil {
			extractDirs = append(extractDirs, extra)
		}
	}

	fmt.Println("  Creating snapshot archive...")
	if err := createArchive(tmpHome, extractDirs, output, outputFmt); err != nil {
		return fmt.Errorf("archive creation failed: %w", err)
	}

	return nil
}

// extractToHome decompresses a snapshot archive into a terpd home directory.
func extractToHome(input, inputFmt, home string) error {
	var cmd *exec.Cmd
	switch inputFmt {
	case "lz4":
		cmd = exec.Command("sh", "-c",
			fmt.Sprintf("lz4 -dc %s | tar xf - -C %s", input, home))
	case "zst", "zstd":
		cmd = exec.Command("sh", "-c",
			fmt.Sprintf("zstd -dc %s | tar xf - -C %s", input, home))
	case "gz", "gzip":
		cmd = exec.Command("sh", "-c",
			fmt.Sprintf("tar xzf %s -C %s", input, home))
	case "tar":
		cmd = exec.Command("tar", "xf", input, "-C", home)
	default:
		return fmt.Errorf("unknown input format: %s", inputFmt)
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%w\n%s", err, string(out))
	}
	return nil
}

// detectFormat guesses compression from file extension.
func detectFormat(path string) string {
	switch {
	case strings.HasSuffix(path, ".tar.lz4"):
		return "lz4"
	case strings.HasSuffix(path, ".tar.zst"), strings.HasSuffix(path, ".tar.zstd"):
		return "zst"
	case strings.HasSuffix(path, ".tar.gz"), strings.HasSuffix(path, ".tgz"):
		return "gz"
	case strings.HasSuffix(path, ".tar"):
		return "tar"
	default:
		return "lz4" // assume lz4 as default
	}
}

func decompressCmd(format, input string) *exec.Cmd {
	switch format {
	case "lz4":
		return exec.Command("lz4", "-dc", input)
	case "zst", "zstd":
		return exec.Command("zstd", "-dc", input)
	case "gz", "gzip":
		return exec.Command("gzip", "-dc", input)
	case "tar":
		return exec.Command("cat", input)
	default:
		return nil
	}
}

func compressCmd(format string) *exec.Cmd {
	switch format {
	case "lz4":
		return exec.Command("lz4", "-c")
	case "zst", "zstd":
		return exec.Command("zstd", "-c", "-T0", "-3")
	case "gz", "gzip":
		return exec.Command("gzip", "-c")
	case "tar", "none":
		return exec.Command("cat")
	default:
		return nil
	}
}

// compactAllLevelDBs walks a directory for LevelDB instances (*.db dirs)
// and runs a full CompactRange on each to rewrite SST files without tombstones.
func compactAllLevelDBs(dataDir string) error {
	entries, err := os.ReadDir(dataDir)
	if err != nil {
		return fmt.Errorf("cannot read data dir: %w", err)
	}

	var lastErr error
	for _, e := range entries {
		if !e.IsDir() || !strings.HasSuffix(e.Name(), ".db") {
			continue
		}
		dbPath := filepath.Join(dataDir, e.Name())

		fmt.Printf("    Compacting %s...\n", e.Name())
		before := dirSize(dbPath)

		db, err := leveldb.OpenFile(dbPath, &opt.Options{})
		if err != nil {
			fmt.Printf("    Warning: cannot open %s: %v\n", e.Name(), err)
			lastErr = err
			continue
		}

		// CompactRange(nil, nil) compacts the entire key range.
		if err := db.CompactRange(util.Range{}); err != nil {
			fmt.Printf("    Warning: compact %s failed: %v\n", e.Name(), err)
			lastErr = err
		}

		db.Close()

		after := dirSize(dbPath)
		fmt.Printf("    %s: %.2f GB → %.2f GB\n", e.Name(),
			float64(before)/(1024*1024*1024),
			float64(after)/(1024*1024*1024))
	}
	return lastErr
}


