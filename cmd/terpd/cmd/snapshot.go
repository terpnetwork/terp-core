package cmd

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/spf13/cobra"

	"github.com/terpnetwork/terp-core/v5/app"
)

var SnapshotCmd = &cobra.Command{
	Use:   "snapshot",
	Short: "Extract a snapshot archive from a node's data directory",
	Long: `Create a compressed snapshot archive (data/ + wasm/) from a terpd home directory.

The node process is frozen with SIGSTOP during extraction and resumed with
SIGCONT immediately after — the container stays running and no data is lost.
The node will catch up from where it left off after resuming.

For large databases (>10 GB), the command will additionally offer to split the
archive into smaller chunks for easier distribution.

Only data/ and wasm/ are extracted — never config/, which contains the node's
identity (node_key.json, priv_validator_key.json).

Examples:
  # Extract snapshot from default home dir
  terpd snapshot -o /tmp/terp-snapshot.tar.lz4

  # Extract from custom home (e.g. Docker container volume)
  terpd snapshot --home /terpd/.terpd -o /tmp/snapshot.tar.lz4

  # Extract with zstd compression
  terpd snapshot -o /tmp/snapshot.tar.zst --format zst

  # Extract and split into 2GB chunks
  terpd snapshot -o /tmp/snapshot.tar.lz4 --split 2G`,
	RunE: runSnapshot,
}

func init() {
	SnapshotCmd.Flags().StringP("output", "o", "", "output file path (required)")
	SnapshotCmd.Flags().String("home", app.DefaultNodeHome, "node home directory")
	SnapshotCmd.Flags().String("format", "lz4", "compression format: lz4, zst, gz, or none")
	SnapshotCmd.Flags().String("split", "", "split output into chunks of this size (e.g. 2G, 500M)")
	SnapshotCmd.MarkFlagRequired("output")
}

func runSnapshot(cmd *cobra.Command, args []string) error {
	home, _ := cmd.Flags().GetString("home")
	output, _ := cmd.Flags().GetString("output")
	format, _ := cmd.Flags().GetString("format")
	splitSize, _ := cmd.Flags().GetString("split")

	// Resolve home directory
	if strings.HasPrefix(home, "~/") {
		if h, err := os.UserHomeDir(); err == nil {
			home = filepath.Join(h, home[2:])
		}
	}

	// Verify data directory exists
	dataDir := filepath.Join(home, "data")
	if _, err := os.Stat(dataDir); os.IsNotExist(err) {
		return fmt.Errorf("data directory not found: %s", dataDir)
	}

	// Determine extraction dirs (data + wasm if present)
	// Include all state directories the node needs to start.
	// data/ is always required, wasm/ and ibc_08-wasm/ are included if present.
	extractDirs := []string{"data"}
	for _, extra := range []string{"wasm", "ibc_08-wasm"} {
		if _, err := os.Stat(filepath.Join(home, extra)); err == nil {
			extractDirs = append(extractDirs, extra)
		}
	}

	// Read pruning config for display
	pruning, keepRecent := readPruningConfig(home)
	dataSize := dirSize(dataDir)

	fmt.Printf("Home:      %s\n", home)
	fmt.Printf("Pruning:   %s\n", pruning)
	if pruning == "custom" {
		fmt.Printf("Keep:      %s recent states\n", keepRecent)
	}
	fmt.Printf("Data size: %.2f GB\n", float64(dataSize)/(1024*1024*1024))
	fmt.Printf("Dirs:      %s\n", strings.Join(extractDirs, ", "))
	fmt.Printf("Output:    %s\n", output)
	fmt.Printf("Format:    %s\n", format)

	// Find running terpd process
	pid := findTerpdProcess(home)

	if pid > 0 {
		fmt.Printf("Found terpd PID: %d\n", pid)

		// Always freeze — never SIGTERM. terpd may be PID 1 in a container,
		// and SIGTERM on PID 1 kills the container, destroying sync progress.
		fmt.Println("Freezing terpd process (SIGSTOP)...")
		if err := syscall.Kill(pid, syscall.SIGSTOP); err != nil {
			return fmt.Errorf("failed to freeze process %d: %w", pid, err)
		}
		defer func() {
			fmt.Println("Resuming terpd process (SIGCONT)...")
			if err := syscall.Kill(pid, syscall.SIGCONT); err != nil {
				fmt.Printf("Warning: failed to resume process %d: %v\n", pid, err)
			} else {
				fmt.Printf("terpd resumed — node will catch up from peers.\n")
			}
		}()
	} else {
		fmt.Println("No running terpd process found — extracting from stopped node.")
	}

	// Extract snapshot
	fmt.Println("Extracting snapshot...")
	start := time.Now()

	if err := createArchive(home, extractDirs, output, format); err != nil {
		return fmt.Errorf("snapshot extraction failed: %w", err)
	}

	elapsed := time.Since(start)
	info, _ := os.Stat(output)
	archiveSize := int64(0)
	if info != nil {
		archiveSize = info.Size()
	}
	fmt.Printf("Snapshot complete: %s (%.2f GB, %s)\n", output, float64(archiveSize)/(1024*1024*1024), elapsed.Round(time.Second))

	// Split into chunks if requested or if large
	if splitSize != "" {
		fmt.Printf("Splitting into %s chunks...\n", splitSize)
		if err := splitArchive(output, splitSize); err != nil {
			return fmt.Errorf("split failed: %w", err)
		}
	} else if archiveSize > 10*1024*1024*1024 {
		fmt.Printf("\nNote: archive is %.1f GB. Use --split 2G to create smaller chunks for easier distribution.\n",
			float64(archiveSize)/(1024*1024*1024))
	}

	return nil
}

// readPruningConfig reads the pruning strategy and keep-recent value from app.toml.
func readPruningConfig(home string) (string, string) {
	appToml := filepath.Join(home, "config", "app.toml")
	data, err := os.ReadFile(appToml)
	if err != nil {
		return "unknown", "0"
	}
	pruning := "default"
	keepRecent := "0"
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "#") {
			continue
		}
		if parts := strings.SplitN(line, "=", 2); len(parts) == 2 {
			key := strings.TrimSpace(parts[0])
			val := strings.TrimSpace(parts[1])
			val = strings.Trim(val, `"'`)
			switch key {
			case "pruning":
				pruning = val
			case "pruning-keep-recent":
				keepRecent = val
			}
		}
	}
	return pruning, keepRecent
}

// dirSize returns the total size of a directory tree in bytes.
func dirSize(path string) int64 {
	var size int64
	filepath.Walk(path, func(_ string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return nil
		}
		size += info.Size()
		return nil
	})
	return size
}

// findTerpdProcess finds a running terpd process using the given home directory.
func findTerpdProcess(home string) int {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return findTerpdPgrep(home)
	}

	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		pid := 0
		if _, err := fmt.Sscanf(entry.Name(), "%d", &pid); err != nil {
			continue
		}
		cmdline, err := os.ReadFile(filepath.Join("/proc", entry.Name(), "cmdline"))
		if err != nil {
			continue
		}
		parts := strings.Split(string(cmdline), "\x00")
		if len(parts) < 2 {
			continue
		}
		cmdStr := strings.Join(parts, " ")
		if strings.Contains(cmdStr, "terpd") && strings.Contains(cmdStr, "start") {
			if strings.Contains(cmdStr, home) || (home == app.DefaultNodeHome && !strings.Contains(cmdStr, "--home")) {
				return pid
			}
		}
	}
	return 0
}

// findTerpdPgrep uses pgrep as a fallback on non-Linux systems.
func findTerpdPgrep(home string) int {
	out, err := exec.Command("pgrep", "-f", fmt.Sprintf("terpd.*start.*%s", home)).Output()
	if err != nil {
		out, err = exec.Command("pgrep", "-f", "terpd.*start").Output()
		if err != nil {
			return 0
		}
	}
	pid := 0
	fmt.Sscanf(strings.TrimSpace(string(out)), "%d", &pid)
	return pid
}

// createArchive creates a compressed tar archive of the given directories.
func createArchive(home string, dirs []string, output string, format string) error {
	outFile, err := os.Create(output)
	if err != nil {
		return fmt.Errorf("cannot create output file: %w", err)
	}
	defer outFile.Close()

	tarArgs := append([]string{"cf", "-", "-C", home}, dirs...)
	tarCmd := exec.Command("tar", tarArgs...)
	tarCmd.Stderr = os.Stderr

	switch format {
	case "lz4":
		return pipeThrough(tarCmd, exec.Command("lz4", "-c"), outFile)
	case "zst", "zstd":
		return pipeThrough(tarCmd, exec.Command("zstd", "-c", "-T0"), outFile)
	case "gz", "gzip":
		return pipeThrough(tarCmd, exec.Command("gzip", "-c"), outFile)
	case "none", "tar":
		tarCmd.Stdout = outFile
		return tarCmd.Run()
	default:
		return fmt.Errorf("unknown format %q — use lz4, zst, gz, or none", format)
	}
}

// pipeThrough connects tar stdout → compressor stdin → output file.
func pipeThrough(tarCmd *exec.Cmd, compCmd *exec.Cmd, outFile *os.File) error {
	pipe, err := tarCmd.StdoutPipe()
	if err != nil {
		return err
	}
	compCmd.Stdin = pipe
	compCmd.Stdout = outFile
	compCmd.Stderr = os.Stderr

	if err := tarCmd.Start(); err != nil {
		return fmt.Errorf("tar start: %w", err)
	}
	if err := compCmd.Start(); err != nil {
		return fmt.Errorf("compressor start: %w", err)
	}

	compErr := compCmd.Wait()
	tarErr := tarCmd.Wait()

	if tarErr != nil {
		return fmt.Errorf("tar: %w", tarErr)
	}
	if compErr != nil {
		return fmt.Errorf("compressor: %w", compErr)
	}
	return nil
}

// splitArchive splits a file into chunks using the split command.
func splitArchive(path string, chunkSize string) error {
	// split -b 2G file.tar.lz4 file.tar.lz4.part-
	prefix := path + ".part-"
	splitCmd := exec.Command("split", "-b", chunkSize, path, prefix)
	splitCmd.Stdout = os.Stdout
	splitCmd.Stderr = os.Stderr
	if err := splitCmd.Run(); err != nil {
		return err
	}

	// List the parts
	parts, _ := filepath.Glob(prefix + "*")
	for _, p := range parts {
		info, _ := os.Stat(p)
		if info != nil {
			fmt.Printf("  %s (%.2f GB)\n", p, float64(info.Size())/(1024*1024*1024))
		}
	}
	fmt.Printf("Split into %d chunks.\n", len(parts))
	return nil
}

// copyStream copies from reader to writer.
func copyStream(dst io.Writer, src io.Reader) error {
	_, err := io.Copy(dst, src)
	return err
}
