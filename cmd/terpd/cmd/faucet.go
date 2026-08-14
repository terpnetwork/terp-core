// test with build:  make build && mv build/terpd $HOME/go/bin/terpd-testnet && terpd-testnet testnet create --faucet-key-name faucet  --faucet --home $HOME/.terpd-testnet --chain-id 120u-1
package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"

	rpchttp "github.com/cometbft/cometbft/rpc/client/http"
	"github.com/cosmos/cosmos-sdk/client"
	"github.com/cosmos/cosmos-sdk/client/tx"
	"github.com/cosmos/cosmos-sdk/crypto/hd"
	"github.com/cosmos/cosmos-sdk/crypto/keyring"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/tx/signing"
	authtypes "github.com/cosmos/cosmos-sdk/x/auth/types"
	banktypes "github.com/cosmos/cosmos-sdk/x/bank/types"

	"cosmossdk.io/math"
	"github.com/terpnetwork/terp-core/v6/app"
	"github.com/terpnetwork/terp-core/v6/app/params"
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
	fmt.Printf("faucet cfg: %v\n", cfg)

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
	if err := waitForNode("tcp://localhost:36657", 120*time.Second); err != nil {
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
	w.Header().Set("Access-Control-Allow-Origin", "*")
	// Browsers always request this; do not surface as a scary 404 page.
	if r.URL.Path == "/favicon.ico" {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	switch r.URL.Path {
	case "/", "/index.html":
		// Prefer HTML for browsers; JSON when explicitly asked.
		accept := r.Header.Get("Accept")
		if r.URL.Query().Get("format") == "json" || (accept != "" && !containsHTMLAccept(accept) && containsJSONAccept(accept)) {
			fs.handleStatus(w)
			return
		}
		fs.handleIndexHTML(w)
	case "/status":
		fs.handleStatus(w)
	case "/faucet":
		addr := r.URL.Query().Get("address")
		if addr == "" {
			// Browser form may land here without query — show UI instead of bare 400.
			if containsHTMLAccept(r.Header.Get("Accept")) && r.Method == http.MethodGet {
				fs.handleIndexHTML(w)
				return
			}
			writeJSON(w, 400, map[string]string{"error": "address is required", "path": "/faucet?address=terp1..."})
			return
		}
		fs.handleFaucet(w, addr)
	default:
		writeJSON(w, 404, map[string]string{
			"error": "not found",
			"paths": "GET / | GET /status | GET /faucet?address=<bech32>",
		})
	}
}

func containsHTMLAccept(a string) bool {
	al := strings.ToLower(a)
	// Browsers send text/html; bare curl often sends */* — treat both as UI-capable.
	return a == "" || strings.Contains(al, "text/html") || strings.Contains(al, "*/*")
}

func containsJSONAccept(a string) bool {
	return strings.Contains(strings.ToLower(a), "application/json")
}

func (fs *faucetServer) handleIndexHTML(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache")
	denoms := ""
	for i, d := range fs.cfg.Denoms {
		if i > 0 {
			denoms += ", "
		}
		denoms += d
	}
	page := fmt.Sprintf(`<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>Terp testnet faucet · %s</title>
<style>
  body{font-family:system-ui,sans-serif;background:#0b0c10;color:#e8eae6;margin:0;padding:2rem;line-height:1.5}
  main{max-width:32rem;margin:0 auto}
  h1{font-size:1.4rem;color:#b1ebeb}
  code,input{font-family:ui-monospace,monospace}
  input{width:100%%;padding:.65rem .75rem;border-radius:8px;border:1px solid #333;background:#15161c;color:#fff;box-sizing:border-box}
  button{margin-top:.75rem;padding:.6rem 1rem;border:0;border-radius:8px;background:#bd93f9;color:#111;font-weight:700;cursor:pointer}
  .muted{color:#8b96b8;font-size:.95rem}
  pre{background:#15161c;padding:1rem;border-radius:8px;overflow:auto;font-size:.85rem}
  a{color:#bd93f9}
</style>
</head>
<body>
<main>
  <h1>Terp testnet faucet</h1>
  <p class="muted">Chain <code>%s</code> · sends <code>%s</code> of each: <code>%s</code></p>
  <p class="muted">Faucet account: <code>%s</code></p>
  <form id="f" action="/faucet" method="get">
    <label for="address">Recipient bech32</label>
    <input id="address" name="address" placeholder="terp1…" required autocomplete="off"/>
    <button type="submit">Request funds</button>
  </form>
  <p class="muted">API: <code>GET /status</code> · <code>GET /faucet?address=terp1…</code></p>
  <p class="muted">RPC: <a href="https://testnet-rpc.terp.network/status">testnet-rpc.terp.network</a></p>
  <pre id="out"></pre>
</main>
<script>
document.getElementById("f").addEventListener("submit", async (e) => {
  e.preventDefault();
  const addr = document.getElementById("address").value.trim();
  const out = document.getElementById("out");
  out.textContent = "requesting…";
  try {
    const r = await fetch("/faucet?address=" + encodeURIComponent(addr));
    const t = await r.text();
    out.textContent = r.status + "\n" + t;
  } catch (err) {
    out.textContent = String(err);
  }
});
</script>
</body>
</html>
`, fs.cfg.ChainID, fs.cfg.ChainID, fs.cfg.Amount, denoms, fs.fromAddr.String())
	_, _ = w.Write([]byte(page))
}

func (fs *faucetServer) handleStatus(w http.ResponseWriter) {
	writeJSON(w, 200, map[string]interface{}{
		"faucet_address": fs.fromAddr.String(),
		"amount":         fs.cfg.Amount,
		"denoms":         fs.cfg.Denoms,
		"chain_id":       fs.cfg.ChainID,
		"paths": map[string]string{
			"ui":     "/",
			"status": "/status",
			"fund":   "/faucet?address={bech32}",
		},
		"url": "https://faucet.terp.network/faucet?address=",
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

	rpcClient, err := rpchttp.New("tcp://localhost:36657", "/websocket")
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
		WithGasPrices("0.5uthiol").
		WithGasAdjustment(1.3).
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
