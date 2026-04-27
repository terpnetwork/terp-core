package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sync"
	"time"

	"github.com/cosmos/cosmos-sdk/client"
	"github.com/cosmos/cosmos-sdk/client/tx"
	"github.com/cosmos/cosmos-sdk/crypto/hd"
	"github.com/cosmos/cosmos-sdk/crypto/keyring"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/tx/signing"
	authtypes "github.com/cosmos/cosmos-sdk/x/auth/types"
	banktypes "github.com/cosmos/cosmos-sdk/x/bank/types"
	rpchttp "github.com/cometbft/cometbft/rpc/client/http"

	"cosmossdk.io/math"
	"github.com/terpnetwork/terp-core/v5/app"
	"github.com/terpnetwork/terp-core/v5/app/params"
)

// FaucetConfig holds faucet runtime configuration.
type FaucetConfig struct {
	Port    int
	Amount  string
	Denoms  []string
	KeyName string
	Home    string
	ChainID string
}

type faucetServer struct {
	cfg      FaucetConfig
	kr       keyring.Keyring
	fromAddr sdk.AccAddress
	encCfg   params.EncodingConfig
	mu       sync.Mutex
}

// runFaucetServer blocks, serving HTTP until ctx is cancelled.
func runFaucetServer(cfg FaucetConfig) error {
	encCfg := app.MakeEncodingConfig()

	kr, err := keyring.New("terpd", keyring.BackendTest, cfg.Home, nil, encCfg.Marshaler)
	if err != nil {
		return fmt.Errorf("open keyring: %w", err)
	}

	rec, err := kr.Key(cfg.KeyName)
	if err != nil {
		return fmt.Errorf("key %q not found: %w", cfg.KeyName, err)
	}
	addr, err := rec.GetAddress()
	if err != nil {
		return fmt.Errorf("get address: %w", err)
	}

	fs := &faucetServer{
		cfg:      cfg,
		kr:       kr,
		fromAddr: addr,
		encCfg:   encCfg,
	}

	// Wait for local node to be ready
	if err := waitForNode("tcp://localhost:26657", 120*time.Second); err != nil {
		return fmt.Errorf("node not ready: %w", err)
	}

	fmt.Printf("[faucet] Listening on :%d (from %s)\n", cfg.Port, addr.String())
	return http.ListenAndServe(fmt.Sprintf(":%d", cfg.Port), fs)
}

func waitForNode(rpcAddr string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		c, err := rpchttp.New(rpcAddr, "/websocket")
		if err == nil {
			status, err := c.Status(context.Background())
			if err == nil && status.SyncInfo.LatestBlockHeight > 0 {
				return nil
			}
		}
		time.Sleep(time.Second)
	}
	return fmt.Errorf("node at %s not reachable after %s", rpcAddr, timeout)
}

func (fs *faucetServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Access-Control-Allow-Origin", "*")

	switch {
	case r.URL.Path == "/" || r.URL.Path == "/status":
		fs.handleStatus(w)
	case r.URL.Path == "/faucet":
		addr := r.URL.Query().Get("address")
		if addr == "" {
			writeJSON(w, 400, map[string]string{"error": "address is required"})
			return
		}
		fs.handleFaucet(w, addr)
	default:
		writeJSON(w, 404, map[string]string{"error": "not found"})
	}
}

func (fs *faucetServer) handleStatus(w http.ResponseWriter) {
	writeJSON(w, 200, map[string]interface{}{
		"faucet_address": fs.fromAddr.String(),
		"amount":         fs.cfg.Amount,
		"denoms":         fs.cfg.Denoms,
	})
}

func (fs *faucetServer) handleFaucet(w http.ResponseWriter, address string) {
	toAddr, err := sdk.AccAddressFromBech32(address)
	if err != nil {
		writeJSON(w, 400, map[string]string{"error": fmt.Sprintf("invalid address: %v", err)})
		return
	}

	txHash, err := fs.sendTokens(context.Background(), toAddr)
	if err != nil {
		writeJSON(w, 500, map[string]string{"error": err.Error()})
		return
	}

	writeJSON(w, 200, map[string]string{"txhash": txHash})
}

func (fs *faucetServer) sendTokens(ctx context.Context, toAddr sdk.AccAddress) (string, error) {
	fs.mu.Lock()
	defer fs.mu.Unlock()

	coins := sdk.Coins{}
	for _, denom := range fs.cfg.Denoms {
		amt, ok := math.NewIntFromString(fs.cfg.Amount)
		if !ok {
			return "", fmt.Errorf("invalid amount: %s", fs.cfg.Amount)
		}
		coins = append(coins, sdk.NewCoin(denom, amt))
	}
	coins = coins.Sort()

	msg := banktypes.NewMsgSend(fs.fromAddr, toAddr, coins)

	rpcClient, err := rpchttp.New("tcp://localhost:26657", "/websocket")
	if err != nil {
		return "", fmt.Errorf("rpc client: %w", err)
	}

	clientCtx := client.Context{}.
		WithCodec(fs.encCfg.Marshaler).
		WithInterfaceRegistry(fs.encCfg.InterfaceRegistry).
		WithTxConfig(fs.encCfg.TxConfig).
		WithKeyring(fs.kr).
		WithFromName(fs.cfg.KeyName).
		WithFromAddress(fs.fromAddr).
		WithBroadcastMode("sync").
		WithChainID(fs.cfg.ChainID).
		WithClient(rpcClient).
		WithAccountRetriever(authtypes.AccountRetriever{})

	txf := tx.Factory{}.
		WithKeybase(fs.kr).
		WithTxConfig(fs.encCfg.TxConfig).
		WithAccountRetriever(authtypes.AccountRetriever{}).
		WithChainID(fs.cfg.ChainID).
		WithGas(200000).
		WithGasPrices("0.025uterp").
		WithSignMode(signing.SignMode_SIGN_MODE_DIRECT)

	// Fetch current account number + sequence
	txf, err = txf.Prepare(clientCtx)
	if err != nil {
		return "", fmt.Errorf("prepare tx: %w", err)
	}

	txBuilder, err := txf.BuildUnsignedTx(msg)
	if err != nil {
		return "", fmt.Errorf("build tx: %w", err)
	}

	err = tx.Sign(ctx, txf, fs.cfg.KeyName, txBuilder, true)
	if err != nil {
		return "", fmt.Errorf("sign tx: %w", err)
	}

	txBytes, err := fs.encCfg.TxConfig.TxEncoder()(txBuilder.GetTx())
	if err != nil {
		return "", fmt.Errorf("encode tx: %w", err)
	}

	res, err := clientCtx.BroadcastTx(txBytes)
	if err != nil {
		return "", fmt.Errorf("broadcast tx: %w", err)
	}
	if res.Code != 0 {
		return "", fmt.Errorf("tx failed code=%d: %s", res.Code, res.RawLog)
	}

	return res.TxHash, nil
}

// recoverKey adds a key from mnemonic if it doesn't already exist.
func recoverKey(kr keyring.Keyring, name, mnemonic string) error {
	_, err := kr.Key(name)
	if err == nil {
		return nil // already exists
	}
	hdPath := sdk.GetConfig().GetFullBIP44Path()
	_, err = kr.NewAccount(name, mnemonic, "", hdPath, hd.Secp256k1)
	return err
}

func writeJSON(w http.ResponseWriter, code int, v interface{}) {
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}
