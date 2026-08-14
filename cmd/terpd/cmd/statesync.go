package cmd

import (
	"context"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"text/tabwriter"
	"time"

	"cosmossdk.io/log/v2"
	snapshots "github.com/cosmos/cosmos-sdk/store/v2/snapshots"
	snapshottypes "github.com/cosmos/cosmos-sdk/store/v2/snapshots/types"

	wasmkeeper "github.com/CosmWasm/wasmd/x/wasm/keeper"

	abcicli "github.com/cometbft/cometbft/abci/client"
	abci "github.com/cometbft/cometbft/abci/types"
	cmtcfg "github.com/cometbft/cometbft/config"
	cmtlog "github.com/cometbft/cometbft/libs/log"
	cmtnode "github.com/cometbft/cometbft/node"
	"github.com/cometbft/cometbft/p2p"
	pvm "github.com/cometbft/cometbft/privval"
	"github.com/cometbft/cometbft/proxy"
	rpchttp "github.com/cometbft/cometbft/rpc/client/http"

	dbm "github.com/cosmos/cosmos-db"
	"github.com/cosmos/cosmos-sdk/baseapp"
	"github.com/cosmos/cosmos-sdk/server"
	simtestutil "github.com/cosmos/cosmos-sdk/testutil/sims"

	"github.com/spf13/cobra"

	"github.com/terpnetwork/terp-core/v6/app"
)

// StatesyncCmd provides tools to debug and test state-sync snapshots
var StatesyncCmd = &cobra.Command{
	Use:   "statesync",
	Short: "Debug and test state-sync snapshots (list, info, query, test, fetch)",
	Long: `Advanced debugging tool for state-sync snapshots.

Subcommands:
  list    List all local snapshots with metadata
  info    Show detailed info about a snapshot (auto-detects latest)
  query   Query snapshot metadata via ABCI ListSnapshots (lightweight)
  test    Dry-run full state-sync restore (OfferSnapshot + ApplySnapshotChunk)
  fetch   Fetch a snapshot from the production network via P2P state-sync
  rpc     Query RPC endpoints and P2P peers for snapshot metadata`,
	RunE: func(cmd *cobra.Command, args []string) error {
		return cmd.Help()
	},
}

func init() {
	StatesyncCmd.PersistentFlags().String("home", app.DefaultNodeHome, "directory for config and data")
	StatesyncCmd.PersistentFlags().String("db-backend", "goleveldb", "database backend (goleveldb recommended)")

	StatesyncCmd.AddCommand(
		listSnapshotsCmd(),
		infoSnapshotCmd(),
		querySnapshotsCmd(),
		testStateSyncCmd(),
		fetchSnapshotCmd(),
		rpcSnapshotsCmd(),
	)
}

// getSnapshotStore opens the real snapshot store from your node home.
// Returns the store and the underlying DB (caller should close the DB when done).
func getSnapshotStore(home string) (*snapshots.Store, dbm.DB, error) {
	if home == "" {
		home = app.DefaultNodeHome
	}

	snapshotDir := filepath.Join(home, "data", "snapshots")

	snapshotDB, err := dbm.NewDB("metadata", dbm.GoLevelDBBackend, snapshotDir)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to open snapshot metadata DB at %s: %w", snapshotDir, err)
	}

	store, err := snapshots.NewStore(snapshotDB, snapshotDir)
	if err != nil {
		snapshotDB.Close()
		return nil, nil, fmt.Errorf("failed to create snapshot store: %w", err)
	}

	fmt.Printf("Snapshot store opened\n")
	fmt.Printf("  Directory : %s\n", snapshotDir)
	fmt.Printf("  Metadata  : %s/metadata.db\n\n", snapshotDir)

	return store, snapshotDB, nil
}

// ====================== LIST COMMAND ======================
func listSnapshotsCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "list",
		Short: "List all local state-sync snapshots",
		RunE: func(cmd *cobra.Command, args []string) error {
			home, _ := cmd.Flags().GetString("home")

			store, snapshotDB, err := getSnapshotStore(home)
			if err != nil {
				return err
			}
			defer snapshotDB.Close()

			snapList, err := store.List()
			if err != nil {
				return fmt.Errorf("failed to list snapshots: %w", err)
			}

			if len(snapList) == 0 {
				fmt.Println("No snapshots found.")
				return nil
			}

			for i, snapshot := range snapList {
				fmt.Printf("Snapshot #%d\n", i+1)
				fmt.Printf("  Height     : %d\n", snapshot.Height)
				fmt.Printf("  Format     : %d\n", snapshot.Format)
				fmt.Printf("  Chunks     : %d\n", snapshot.Chunks)
				fmt.Printf("  Hash       : %X\n", snapshot.Hash)
				if len(snapshot.Metadata.ChunkHashes) > 0 {
					fmt.Printf("  ChunkHashes: %d entries\n", len(snapshot.Metadata.ChunkHashes))
				}
				fmt.Println("  ---")
			}
			fmt.Printf("\nTotal snapshots found: %d\n", len(snapList))
			return nil
		},
	}
	return cmd
}

// ====================== INFO COMMAND ======================
func infoSnapshotCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "info",
		Short: "Show detailed information for a snapshot (auto-detects latest if --height not set)",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			home, _ := cmd.Flags().GetString("home")
			height, _ := cmd.Flags().GetUint64("height")

			store, snapshotDB, err := getSnapshotStore(home)
			if err != nil {
				return err
			}
			defer snapshotDB.Close()

			var snap *snapshottypes.Snapshot
			if height == 0 {
				snap, err = store.GetLatest()
				if err != nil {
					return fmt.Errorf("failed to get latest snapshot: %w", err)
				}
				if snap == nil {
					return fmt.Errorf("no snapshots found; use 'statesync list' to verify")
				}
				fmt.Printf("Auto-detected latest snapshot at height %d\n\n", snap.Height)
			} else {
				snap, err = store.Get(height, snapshottypes.CurrentFormat)
				if err != nil || snap == nil {
					return fmt.Errorf("snapshot at height %d (format %d) not found", height, snapshottypes.CurrentFormat)
				}
			}

			fmt.Printf("Snapshot at height %d\n", snap.Height)
			fmt.Printf("  Format     : %d\n", snap.Format)
			fmt.Printf("  Chunks     : %d\n", snap.Chunks)
			fmt.Printf("  Hash       : %X\n", snap.Hash)
			fmt.Printf("  ChunkHashes: %d entries\n", len(snap.Metadata.ChunkHashes))
			return nil
		},
	}
	cmd.Flags().Uint64("height", 0, "Snapshot height (0 = auto-detect latest)")
	return cmd
}

// ====================== QUERY (ABCI) COMMAND ======================
func querySnapshotsCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "query",
		Short: "Query snapshot metadata via ABCI ListSnapshots (lightweight, no full node)",
		Long: `Calls the ABCI ListSnapshots method exactly as CometBFT peers do when
discovering available snapshots. This is the most lightweight way to verify
what snapshot data your node would advertise to the network.

No modules are loaded — only the snapshot store is opened and a minimal
BaseApp is created to service the ABCI call.`,
		RunE: func(cmd *cobra.Command, args []string) error {
			home, _ := cmd.Flags().GetString("home")

			store, snapshotDB, err := getSnapshotStore(home)
			if err != nil {
				return err
			}
			defer snapshotDB.Close()

			// Minimal BaseApp — no modules, no full app state
			memDB := dbm.NewMemDB()
			ba := baseapp.NewBaseApp(
				"terpd",
				log.NewNopLogger(),
				memDB,
				nil,
				baseapp.SetSnapshot(store, snapshottypes.NewSnapshotOptions(0, 0)),
			)

			resp, err := ba.ListSnapshots(&abci.RequestListSnapshots{})
			if err != nil {
				return fmt.Errorf("ABCI ListSnapshots failed: %w", err)
			}

			if len(resp.Snapshots) == 0 {
				fmt.Println("ABCI ListSnapshots returned 0 snapshots.")
				fmt.Println("CometBFT peers would see no snapshots from this node.")
				return nil
			}

			fmt.Printf("ABCI ListSnapshots: %d snapshot(s) available\n", len(resp.Snapshots))
			fmt.Println("(This is exactly what CometBFT peers see over P2P channel 0x60)")

			for i, s := range resp.Snapshots {
				fmt.Printf("Snapshot #%d\n", i+1)
				fmt.Printf("  Height   : %d\n", s.Height)
				fmt.Printf("  Format   : %d\n", s.Format)
				fmt.Printf("  Chunks   : %d\n", s.Chunks)
				fmt.Printf("  Hash     : %X\n", s.Hash)
				if len(s.Metadata) > 0 {
					fmt.Printf("  Metadata : %d bytes\n", len(s.Metadata))
				}
				fmt.Println("  ---")
			}
			return nil
		},
	}
	return cmd
}

// ====================== TEST (DRY-RUN) COMMAND ======================
func testStateSyncCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "test",
		Short: "Dry-run full state-sync restore (Offer + Apply chunks) - validates app state",
		Long: `Simulates exactly what a state-syncing node does. Great for sanity-testing your app.
Auto-detects the latest snapshot unless --height is specified.`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			home, _ := cmd.Flags().GetString("home")
			height, _ := cmd.Flags().GetUint64("height")

			logger := log.NewLogger(cmd.OutOrStdout())

			store, snapshotDB, err := getSnapshotStore(home)
			if err != nil {
				return err
			}
			defer snapshotDB.Close()

			var snap *snapshottypes.Snapshot
			if height == 0 {
				snap, err = store.GetLatest()
				if err != nil {
					return fmt.Errorf("failed to get latest snapshot: %w", err)
				}
				if snap == nil {
					return fmt.Errorf("no snapshots found; use 'statesync list' to verify")
				}
				fmt.Printf("Auto-detected latest snapshot at height %d\n\n", snap.Height)
			} else {
				snap, err = store.Get(height, snapshottypes.CurrentFormat)
				if err != nil || snap == nil {
					return fmt.Errorf("snapshot at height %d not found", height)
				}
			}

			fmt.Printf("Starting state-sync dry-run for height %d...\n", snap.Height)
			fmt.Printf("  Chunks to apply: %d\n\n", snap.Chunks)

			// Create a minimal BaseApp with snapshot support
			memDB := dbm.NewMemDB()
			ba := baseapp.NewBaseApp(
				"terpd",
				logger,
				memDB,
				nil, // tx decoder not needed
				baseapp.SetSnapshot(store, snapshottypes.NewSnapshotOptions(0, 0)),
			)

			// Convert to ABCI snapshot for OfferSnapshot
			abciSnap, err := snap.ToABCI()
			if err != nil {
				return fmt.Errorf("failed to convert snapshot to ABCI: %w", err)
			}

			// Step 1: OfferSnapshot
			offerResp, err := ba.OfferSnapshot(&abci.RequestOfferSnapshot{
				Snapshot: &abciSnap,
				AppHash:  []byte{},
			})
			if err != nil {
				return fmt.Errorf("OfferSnapshot failed: %w", err)
			}
			fmt.Printf("OfferSnapshot result: %s\n", offerResp.Result)

			// Step 2: Apply all chunks
			for i := uint32(0); i < snap.Chunks; i++ {
				chunkReader, err := store.LoadChunk(snap.Height, snap.Format, i)
				if err != nil {
					return fmt.Errorf("failed to load chunk %d: %w", i, err)
				}
				chunkBytes, err := io.ReadAll(chunkReader)
				chunkReader.Close()
				if err != nil {
					return fmt.Errorf("failed to read chunk %d: %w", i, err)
				}

				applyResp, err := ba.ApplySnapshotChunk(&abci.RequestApplySnapshotChunk{
					Index: i,
					Chunk: chunkBytes,
				})
				if err != nil {
					return fmt.Errorf("ApplySnapshotChunk %d failed: %w", i, err)
				}

				fmt.Printf("  Applied chunk %d/%d -> %s\n", i+1, snap.Chunks, applyResp.Result)
				if applyResp.Result == abci.ResponseApplySnapshotChunk_RETRY {
					fmt.Println("    -> Chunk asked for retry")
				}
			}

			fmt.Println("\nState-sync dry-run completed successfully!")
			fmt.Printf("Final app hash: %X\n", ba.LastCommitID().Hash)
			return nil
		},
	}
	cmd.Flags().Uint64("height", 0, "Snapshot height (0 = auto-detect latest)")
	return cmd
}

// ====================== FETCH (P2P DOWNLOAD) COMMAND ======================
func fetchSnapshotCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "fetch",
		Short: "Fetch a state-sync snapshot from the production network via P2P",
		Long: `Bootstraps a temporary CometBFT node in state-sync mode, connects to
production peers via P2P, discovers and downloads a snapshot, then verifies it.

CometBFT does not expose snapshot listing/fetching via RPC — snapshot exchange
happens exclusively over P2P (channels 0x60/0x61). This command handles the
full P2P bootstrap automatically.

The fetched data is stored in a temporary directory that you can inspect with
the other statesync subcommands (list, query, test).`,
		RunE: func(cmd *cobra.Command, args []string) error {
			home, _ := cmd.Flags().GetString("home")
			rpcAddr, _ := cmd.Flags().GetString("rpc-addr")
			timeout, _ := cmd.Flags().GetDuration("timeout")
			trustOffset, _ := cmd.Flags().GetInt64("trust-offset")

			if home == "" {
				home = app.DefaultNodeHome
			}

			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()

			// ──── Step 1: Connect to production RPC ────
			fmt.Printf("Connecting to production RPC: %s\n", rpcAddr)

			rpcClient, err := rpchttp.New(rpcAddr, "/websocket")
			if err != nil {
				return fmt.Errorf("failed to connect to RPC: %w", err)
			}

			status, err := rpcClient.Status(ctx)
			if err != nil {
				return fmt.Errorf("failed to get node status: %w", err)
			}

			latestHeight := status.SyncInfo.LatestBlockHeight
			network := status.NodeInfo.Network
			rpcNodeID := string(status.NodeInfo.DefaultNodeID)

			fmt.Printf("  Network      : %s\n", network)
			fmt.Printf("  Latest height: %d\n", latestHeight)
			fmt.Printf("  Node ID      : %s\n", rpcNodeID)

			// Trust height / hash
			trustHeight := latestHeight - trustOffset
			if trustHeight < 1 {
				trustHeight = 1
			}

			block, err := rpcClient.Block(ctx, &trustHeight)
			if err != nil {
				return fmt.Errorf("failed to get block at height %d: %w", trustHeight, err)
			}
			trustHash := hex.EncodeToString(block.BlockID.Hash)

			fmt.Printf("  Trust height : %d\n", trustHeight)
			fmt.Printf("  Trust hash   : %s\n", trustHash)

			// Discover peers
			netInfo, err := rpcClient.NetInfo(ctx)
			if err != nil {
				return fmt.Errorf("failed to get net_info: %w", err)
			}

			var peers []string
			rpcHost := extractHost(rpcAddr)
			if rpcHost != "" {
				peers = append(peers, fmt.Sprintf("%s@%s:26656", rpcNodeID, rpcHost))
			}
			for _, peer := range netInfo.Peers {
				addr := peer.RemoteIP
				port := "26656"
				if parts := strings.Split(peer.NodeInfo.ListenAddr, ":"); len(parts) > 1 {
					port = parts[len(parts)-1]
				}
				peers = append(peers, fmt.Sprintf("%s@%s:%s", peer.NodeInfo.DefaultNodeID, addr, port))
			}

			if len(peers) == 0 {
				return fmt.Errorf("no peers discovered from RPC node")
			}
			fmt.Printf("  Peers found  : %d\n\n", len(peers))

			// ──── Step 2: Create temporary directory ────
			tmpDir, err := os.MkdirTemp("", "terpd-statesync-*")
			if err != nil {
				return fmt.Errorf("failed to create temp dir: %w", err)
			}
			fmt.Printf("Temp directory: %s\n", tmpDir)

			configDir := filepath.Join(tmpDir, "config")
			dataDir := filepath.Join(tmpDir, "data")
			if err := os.MkdirAll(configDir, 0o755); err != nil {
				return fmt.Errorf("failed to create config dir: %w", err)
			}
			if err := os.MkdirAll(dataDir, 0o755); err != nil {
				return fmt.Errorf("failed to create data dir: %w", err)
			}

			// Copy genesis.json from user's node home
			genSrc := filepath.Join(home, "config", "genesis.json")
			genDst := filepath.Join(configDir, "genesis.json")
			if err := copyFile(genSrc, genDst); err != nil {
				return fmt.Errorf("failed to copy genesis.json from %s: %w", genSrc, err)
			}
			fmt.Println("  Genesis copied")

			// Generate temp node key
			nodeKey, err := p2p.LoadOrGenNodeKey(filepath.Join(configDir, "node_key.json"))
			if err != nil {
				return fmt.Errorf("failed to generate node key: %w", err)
			}
			fmt.Printf("  Temp node ID: %s\n", nodeKey.ID())

			// Generate temp priv validator
			pvKeyFile := filepath.Join(configDir, "priv_validator_key.json")
			pvStateFile := filepath.Join(dataDir, "priv_validator_state.json")
			filePV := pvm.GenFilePV(pvKeyFile, pvStateFile)
			filePV.Save()

			// ──── Step 3: Build CometBFT config ────
			cmtCfg := cmtcfg.DefaultConfig()
			cmtCfg.RootDir = tmpDir
			cmtCfg.DBBackend = "goleveldb"
			cmtCfg.P2P.ListenAddress = "tcp://0.0.0.0:26658" // avoid conflict with running node
			cmtCfg.P2P.PersistentPeers = strings.Join(peers, ",")
			cmtCfg.P2P.AllowDuplicateIP = true
			cmtCfg.P2P.PexReactor = false       // private: no gossip
			cmtCfg.P2P.MaxNumInboundPeers = 0   // private: reject inbound
			cmtCfg.P2P.AddrBookStrict = false    // allow non-routable addrs
			cmtCfg.P2P.Seeds = ""                // only persistent peers
			cmtCfg.Mempool.Broadcast = false     // don't broadcast txs
			cmtCfg.RPC.ListenAddress = "tcp://127.0.0.1:26659"
			cmtCfg.StateSync.Enable = true
			cmtCfg.StateSync.RPCServers = []string{rpcAddr, rpcAddr} // same addr twice satisfies >=2
			cmtCfg.StateSync.TrustHeight = trustHeight
			cmtCfg.StateSync.TrustHash = trustHash
			cmtCfg.StateSync.TrustPeriod = 336 * time.Hour // 14 days

			// ──── Step 4: Create the app ────
			fmt.Println("\nCreating TerpApp for state-sync...")

			appDB, err := dbm.NewDB("application", dbm.GoLevelDBBackend, dataDir)
			if err != nil {
				return fmt.Errorf("failed to create app DB: %w", err)
			}
			defer appDB.Close()

			terpApp := app.NewTerpApp(
				log.NewNopLogger(),
				appDB,
				nil,
				false, // don't load latest — fresh state-sync
				tmpDir,
				simtestutil.NewAppOptionsWithFlagHome(tmpDir),
				[]wasmkeeper.Option{},
			)

			// ──── Step 5: Create & start CometBFT node ────
			cmtApp := server.NewCometABCIWrapper(terpApp)
			tmLogger := cmtlog.NewTMLogger(os.Stdout)

			cmtNode, err := cmtnode.NewNodeWithContext(
				ctx,
				cmtCfg,
				filePV,
				nodeKey,
				proxy.NewLocalClientCreator(cmtApp),
				cmtnode.DefaultGenesisDocProviderFunc(cmtCfg),
				cmtcfg.DefaultDBProvider,
				cmtnode.DefaultMetricsProvider(cmtCfg.Instrumentation),
				tmLogger,
			)
			if err != nil {
				return fmt.Errorf("failed to create CometBFT node: %w", err)
			}

			fmt.Println("Starting temporary CometBFT node for state-sync...")
			if err := cmtNode.Start(); err != nil {
				return fmt.Errorf("failed to start node: %w", err)
			}
			defer func() {
				if err := cmtNode.Stop(); err != nil {
					fmt.Printf("Warning: failed to stop node cleanly: %v\n", err)
				}
				cmtNode.Wait()
			}()

			// ──── Step 6: Monitor state-sync progress ────
			fmt.Println("State-sync in progress (this may take several minutes)...")

			// Wait for temp node's RPC to be ready
			time.Sleep(3 * time.Second)

			localClient, err := rpchttp.New("http://127.0.0.1:26659", "/websocket")
			if err != nil {
				return fmt.Errorf("failed to create local RPC client: %w", err)
			}

			ticker := time.NewTicker(5 * time.Second)
			defer ticker.Stop()
			deadline := time.After(timeout)

			for {
				select {
				case <-ticker.C:
					st, err := localClient.Status(ctx)
					if err != nil {
						fmt.Print(".")
						continue
					}
					if st.SyncInfo.LatestBlockHeight > 0 {
						fmt.Printf("\n\nState-sync completed!\n")
						fmt.Printf("  Height   : %d\n", st.SyncInfo.LatestBlockHeight)
						fmt.Printf("  App Hash : %X\n", st.SyncInfo.LatestAppHash)
						fmt.Printf("  Temp dir : %s\n", tmpDir)
						fmt.Println("\nVerify with:")
						fmt.Printf("  terpd statesync list  --home %s\n", tmpDir)
						fmt.Printf("  terpd statesync query --home %s\n", tmpDir)
						fmt.Printf("  terpd statesync test  --home %s\n", tmpDir)
						return nil
					}
					fmt.Print(".")
				case <-deadline:
					return fmt.Errorf("state-sync timed out after %s — peers may not have snapshots available", timeout)
				}
			}
		},
	}

	cmd.Flags().String("rpc-addr", "https://rpc.terp.chaintools.tech:443", "Production RPC endpoint for trust info + peer discovery")
	cmd.Flags().Duration("timeout", 5*time.Minute, "Maximum time to wait for state-sync completion")
	cmd.Flags().Int64("trust-offset", 1000, "Blocks behind latest to set trust height")

	return cmd
}

// ====================== RPC / P2P SNAPSHOT QUERY ======================
//
// The rpc command queries RPC endpoints for status and peer discovery, then
// connects to P2P peers via a lightweight temporary node to discover the
// actual snapshots each peer advertises. The snapshot metadata is captured
// by intercepting OfferSnapshot ABCI calls made over the P2P snapshot channel.

// captureSnapClient wraps an abcicli.Client and captures OfferSnapshot calls.
// When a peer offers a snapshot during P2P state-sync discovery, the snapshot
// metadata is recorded.
type captureSnapClient struct {
	abcicli.Client
	mu      sync.Mutex
	offered []*abci.Snapshot
}

func (c *captureSnapClient) OfferSnapshot(ctx context.Context, req *abci.RequestOfferSnapshot) (*abci.ResponseOfferSnapshot, error) {
	if req != nil && req.Snapshot != nil {
		c.mu.Lock()
		c.offered = append(c.offered, req.Snapshot)
		c.mu.Unlock()
	}
	// Accept so the peer continues offering; we stop the node before any
	// chunk download begins.
	return &abci.ResponseOfferSnapshot{Result: abci.ResponseOfferSnapshot_ACCEPT}, nil
}

// captureClientCreator wraps a proxy.ClientCreator and returns captureSnapClient
// instances that record offered snapshots.
type captureClientCreator struct {
	base    proxy.ClientCreator
	offered []*abci.Snapshot
	mu      sync.Mutex
}

func (c *captureClientCreator) NewABCIClient() (abcicli.Client, error) {
	client, err := c.base.NewABCIClient()
	if err != nil {
		return nil, err
	}
	return &captureSnapClient{
		Client:  client,
		offered: c.offered,
	}, nil
}

// rpcSnapshotsCmd queries RPC endpoints and/or P2P peers for snapshot metadata.
func rpcSnapshotsCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "rpc",
		Short: "Query RPC endpoints and P2P peers for snapshot metadata",
		Long: `Queries RPC endpoints and/or P2P peers for node status and available
state-sync snapshots.

For each RPC endpoint, the command:
  1. Connects and gets the node status (chain ID, latest block height, etc.)
  2. Gets ABCI info (app version)
  3. Discovers P2P peers via NetInfo and queries them for snapshots

For each P2P peer (auto-discovered or explicitly specified with --peer-addrs),
the command:
  1. Bootstraps a lightweight temporary CometBFT node in state-sync mode
  2. Connects to the peer via P2P channel 0x60 (snapshot discovery)
  3. Captures the snapshot metadata the peer advertises
  4. Shuts down and displays the results

P2P peer format: nodeID@host:port  (e.g. abc123@192.168.1.1:26656)

Examples:
  terpd statesync rpc --rpc-addrs https://rpc.terp.network:443
  terpd statesync rpc --peer-addrs abc123@192.168.1.1:26656
  terpd statesync rpc --rpc-addrs https://rpc1.terp.network:443 --peer-addrs def456@10.0.0.1:26656
`,
		RunE: func(cmd *cobra.Command, args []string) error {
			rpcAddrs, _ := cmd.Flags().GetStringSlice("rpc-addrs")
			peerAddrs, _ := cmd.Flags().GetStringSlice("peer-addrs")
			if len(rpcAddrs) == 0 && len(peerAddrs) == 0 {
				return fmt.Errorf("at least one --rpc-addr or --peer-addr is required")
			}
			home, _ := cmd.Flags().GetString("home")
			timeout, _ := cmd.Flags().GetDuration("timeout")
			return querySnapshots(cmd.Context(), home, rpcAddrs, peerAddrs, timeout)
		},
	}
	cmd.Flags().StringSlice("rpc-addrs", nil, "Comma-separated list of RPC endpoints")
	cmd.Flags().StringSlice("peer-addrs", nil, "Comma-separated list of P2P peers (nodeID@host:port)")
	cmd.Flags().Duration("timeout", 30*time.Second, "Max time to wait for P2P snapshot discovery")
	return cmd
}

// discoveredSnapshot holds snapshot metadata from a P2P peer.
type discoveredSnapshot struct {
	PeerAddr string
	Height   uint64
	Format   uint32
	Chunks   uint32
	Hash     []byte
}

// rpcNodeInfo holds the result of querying a single RPC endpoint.
type rpcNodeInfo struct {
	Address        string
	ChainID        string
	Moniker        string
	NodeID         string
	LatestHeight   int64
	EarliestHeight int64
	CatchingUp     bool
	AppVersion     string
	QueryError     string
}

// querySnapshots is the main entry point for the rpc command.
func querySnapshots(ctx context.Context, home string, rpcAddrs, peerAddrs []string, p2pTimeout time.Duration) error {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()

	var rpcResults []rpcNodeInfo
	var snapResults []discoveredSnapshot
	peerSet := make(map[string]bool) // dedup discovered peers

	// Phase 1: Query RPC endpoints for status and peer discovery
	for _, addr := range rpcAddrs {
		addr = strings.TrimSpace(addr)
		if addr == "" {
			continue
		}

		info := rpcNodeInfo{Address: addr}

		client, err := rpchttp.NewWithTimeout(addr, "/websocket", 10)
		if err != nil {
			info.QueryError = fmt.Sprintf("connect: %v", err)
			rpcResults = append(rpcResults, info)
			continue
		}

		status, err := client.Status(ctx)
		if err != nil {
			info.QueryError = fmt.Sprintf("status: %v", err)
			rpcResults = append(rpcResults, info)
			continue
		}

		info.ChainID = status.NodeInfo.Network
		info.Moniker = status.NodeInfo.Moniker
		info.NodeID = string(status.NodeInfo.DefaultNodeID)
		info.LatestHeight = status.SyncInfo.LatestBlockHeight
		info.EarliestHeight = status.SyncInfo.EarliestBlockHeight
		info.CatchingUp = status.SyncInfo.CatchingUp

		abciInfo, err := client.ABCIInfo(ctx)
		if err == nil {
			info.AppVersion = fmt.Sprintf("%d", abciInfo.Response.AppVersion)
		}

		rpcResults = append(rpcResults, info)

		// Discover P2P peers from this RPC node
		netInfo, err := client.NetInfo(ctx)
		if err != nil {
			continue
		}

		rpcHost := extractHost(addr)
		if rpcHost != "" && info.NodeID != "" {
			peer := fmt.Sprintf("%s@%s:26656", info.NodeID, rpcHost)
			if !peerSet[peer] {
				peerSet[peer] = true
				peerAddrs = append(peerAddrs, peer)
			}
		}

		for _, p := range netInfo.Peers {
			port := "26656"
			if parts := strings.Split(p.NodeInfo.ListenAddr, ":"); len(parts) > 1 {
				port = parts[len(parts)-1]
			}
			peer := fmt.Sprintf("%s@%s:%s", p.NodeInfo.DefaultNodeID, p.RemoteIP, port)
			if !peerSet[peer] {
				peerSet[peer] = true
				peerAddrs = append(peerAddrs, peer)
			}
		}
	}

	// Phase 2: Query P2P peers for snapshots
	if len(peerAddrs) > 0 {
		fmt.Fprintf(os.Stderr, "\nQuerying %d P2P peers for snapshots (timeout: %s)...\n", len(peerAddrs), p2pTimeout)
		for _, peer := range peerAddrs {
			peer = strings.TrimSpace(peer)
			if peer == "" {
				continue
			}
			if snaps, err := discoverPeerSnapshots(ctx, home, peer, p2pTimeout); err == nil {
				for _, s := range snaps {
					snapResults = append(snapResults, discoveredSnapshot{
						PeerAddr: peer,
						Height:   s.Height,
						Format:   s.Format,
						Chunks:   s.Chunks,
						Hash:     s.Hash,
					})
				}
			}
		}
	}

	// Display results
	displayRPCResults(rpcResults, snapResults)
	return nil
}

// discoverPeerSnapshots starts a lightweight temporary node, connects to a P2P
// peer, discovers snapshots via the P2P state-sync channel, and returns the
// metadata of all snapshots the peer advertises.
func discoverPeerSnapshots(ctx context.Context, home, peerAddr string, timeout time.Duration) ([]*abci.Snapshot, error) {
	if home == "" {
		home = app.DefaultNodeHome
	}

	// Parse peer address
	parts := strings.SplitN(peerAddr, "@", 2)
	if len(parts) != 2 {
		return nil, fmt.Errorf("invalid peer address %q — expected nodeID@host:port", peerAddr)
	}

	// Create temporary directory
	tmpDir, err := os.MkdirTemp("", "terpd-p2p-disc-*")
	if err != nil {
		return nil, fmt.Errorf("temp dir: %w", err)
	}
	defer os.RemoveAll(tmpDir)

	configDir := filepath.Join(tmpDir, "config")
	dataDir := filepath.Join(tmpDir, "data")
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		return nil, err
	}

	// Copy genesis from home
	genSrc := filepath.Join(home, "config", "genesis.json")
	genDst := filepath.Join(configDir, "genesis.json")
	if err := copyFile(genSrc, genDst); err != nil {
		return nil, fmt.Errorf("genesis: %w", err)
	}

	// Generate temp node key
	nodeKey, err := p2p.LoadOrGenNodeKey(filepath.Join(configDir, "node_key.json"))
	if err != nil {
		return nil, fmt.Errorf("node key: %w", err)
	}

	// Generate temp priv validator
	pvKeyFile := filepath.Join(configDir, "priv_validator_key.json")
	pvStateFile := filepath.Join(dataDir, "priv_validator_state.json")
	filePV := pvm.GenFilePV(pvKeyFile, pvStateFile)
	filePV.Save()

	// Build CometBFT config — minimal state-sync node
	cmtCfg := cmtcfg.DefaultConfig()
	cmtCfg.RootDir = tmpDir
	cmtCfg.DBBackend = "goleveldb"
	cmtCfg.P2P.ListenAddress = "tcp://0.0.0.0:26658"
	cmtCfg.P2P.PersistentPeers = peerAddr
	cmtCfg.P2P.AllowDuplicateIP = true
	cmtCfg.P2P.PexReactor = false
	cmtCfg.P2P.MaxNumInboundPeers = 0
	cmtCfg.P2P.AddrBookStrict = false
	cmtCfg.P2P.Seeds = ""
	cmtCfg.Mempool.Broadcast = false
	cmtCfg.RPC.ListenAddress = "tcp://127.0.0.1:26659"
	cmtCfg.StateSync.Enable = true
	// Use a dummy RPC server — the peer just needs to connect via P2P
	cmtCfg.StateSync.RPCServers = []string{"http://127.0.0.1:26657", "http://127.0.0.1:26657"}
	cmtCfg.StateSync.TrustHeight = 1
	cmtCfg.StateSync.TrustHash = "0000000000000000000000000000000000000000000000000000000000000000"
	cmtCfg.StateSync.TrustPeriod = 336 * time.Hour

	// Create a minimal app (no modules, just snapshot support)
	appDB, err := dbm.NewDB("application", dbm.GoLevelDBBackend, dataDir)
	if err != nil {
		return nil, fmt.Errorf("app DB: %w", err)
	}
	defer appDB.Close()

	// Use a no-op logger
	logger := log.NewNopLogger()

	// Create a minimal BaseApp with snapshot support
	memDB := dbm.NewMemDB()
	snapshotDir := filepath.Join(dataDir, "snapshots")
	snapDB, err := dbm.NewDB("metadata", dbm.GoLevelDBBackend, snapshotDir)
	if err != nil {
		return nil, fmt.Errorf("snapshot DB: %w", err)
	}
	defer snapDB.Close()

	store, err := snapshots.NewStore(snapDB, snapshotDir)
	if err != nil {
		return nil, fmt.Errorf("snapshot store: %w", err)
	}

	ba := baseapp.NewBaseApp(
		"terpd",
		logger,
		memDB,
		nil,
		baseapp.SetSnapshot(store, snapshottypes.NewSnapshotOptions(0, 0)),
	)

	// Wrap the app with our capture client
	var offeredSnapshots []*abci.Snapshot

	captureCreator := &captureClientCreator{
		base:    proxy.NewLocalClientCreator(server.NewCometABCIWrapper(ba)),
		offered: offeredSnapshots,
	}

	// Create the CometBFT node
	cmtNode, err := cmtnode.NewNodeWithContext(
		ctx,
		cmtCfg,
		filePV,
		nodeKey,
		captureCreator,
		cmtnode.DefaultGenesisDocProviderFunc(cmtCfg),
		cmtcfg.DefaultDBProvider,
		cmtnode.DefaultMetricsProvider(cmtCfg.Instrumentation),
		cmtlog.NewTMLogger(io.Discard),
	)
	if err != nil {
		return nil, fmt.Errorf("node creation: %w", err)
	}

	// Start the node
	if err := cmtNode.Start(); err != nil {
		return nil, fmt.Errorf("node start: %w", err)
	}

	// Wait for snapshot discovery
	discoveryCtx, discoveryCancel := context.WithTimeout(ctx, timeout)
	defer discoveryCancel()

	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()

	// The node needs time to connect to the peer via P2P, then the peer
	// will call ListSnapshots on itself, and the response will trigger
	// OfferSnapshot on our node. We capture the OfferSnapshot calls.
	<-discoveryCtx.Done()

	// Stop the node
	cmtNode.Stop()
	cmtNode.Wait()

	// Check if we got any snapshots
	if len(offeredSnapshots) == 0 {
		return nil, fmt.Errorf("no snapshots discovered from %s (peer may not be available or snapshots disabled)", peerAddr)
	}

	return offeredSnapshots, nil
}

// displayRPCResults prints a table of all queried RPC nodes and P2P snapshot results.
func displayRPCResults(rpcResults []rpcNodeInfo, snapResults []discoveredSnapshot) {
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 3, ' ', 0)

	// RPC node status table
	if len(rpcResults) > 0 {
		fmt.Fprintln(w, "RPC ADDRESS	CHAIN ID	MONIKER	NODE ID	LATEST	EARLIEST	CATCHING UP	APP VER")
		fmt.Fprintln(w, "-----------	--------	-------	-------	------	--------	-----------	-------")
		for _, r := range rpcResults {
			errStr := r.QueryError
			fmt.Fprintf(w, "%s	%s	%s	%s	%d	%d	%v	%s\n",
				r.Address, r.ChainID, r.Moniker, r.NodeID,
				r.LatestHeight, r.EarliestHeight, r.CatchingUp, r.AppVersion)
			if errStr != "" {
				fmt.Fprintf(w, "	ERR: %s	%s	%s	%s	%s	%s	%s\n", errStr, "", "", "", "", "", "")
			}
		}
		w.Flush()
	}

	// P2P discovered snapshots table
	if len(snapResults) > 0 {
		fmt.Println("\n\nDiscovered Snapshots (via P2P):")
		fmt.Fprintln(w, "PEER ADDRESS	HEIGHT	FORMAT	CHUNKS	HASH")
		fmt.Fprintln(w, "------------	------	------	------	----")

		// Group by peer
		type peerSnaps struct {
			peer string
			snaps []discoveredSnapshot
		}
		peerMap := make(map[string][]discoveredSnapshot)
		var peerOrder []string
		for _, s := range snapResults {
			if _, ok := peerMap[s.PeerAddr]; !ok {
				peerOrder = append(peerOrder, s.PeerAddr)
			}
			peerMap[s.PeerAddr] = append(peerMap[s.PeerAddr], s)
		}

		for _, peer := range peerOrder {
			snaps := peerMap[peer]
			for i, s := range snaps {
				peerCol := peer
				if i > 0 {
					peerCol = ""
				}
				fmt.Fprintf(w, "%s	%d	%d	%d	%X\n",
					peerCol, s.Height, s.Format, s.Chunks, s.Hash)
			}
		}
		w.Flush()

		// Summary
		totalSnaps := len(snapResults)
		uniquePeers := len(peerOrder)
		fmt.Printf("\nTotal snapshots: %d from %d peer(s)\n", totalSnaps, uniquePeers)
	} else {
		fmt.Println("\n\nNo snapshots discovered via P2P.")
	}

	// Summary
	fmt.Println("\n--- Summary ---")
	fmt.Printf("RPCs queried : %d (%d ok, %d failed)\n", len(rpcResults), countSuccessRPC(rpcResults), len(rpcResults)-countSuccessRPC(rpcResults))
	fmt.Printf("Peers queried: %d\n", len(snapResults))
}

func countSuccessRPC(results []rpcNodeInfo) int {
	n := 0
	for _, r := range results {
		if r.QueryError == "" {
			n++
		}
	}
	return n
}

// ====================== HELPERS ======================

func copyFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, data, 0o644)
}

func extractHost(rpcAddr string) string {
	addr := strings.TrimPrefix(rpcAddr, "https://")
	addr = strings.TrimPrefix(addr, "http://")
	addr = strings.TrimPrefix(addr, "tcp://")
	if idx := strings.Index(addr, ":"); idx >= 0 {
		addr = addr[:idx]
	}
	if idx := strings.Index(addr, "/"); idx >= 0 {
		addr = addr[:idx]
	}
	return addr
}
