package app

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sync"
	"time"

	"cosmossdk.io/math"
	"github.com/cosmos/cosmos-sdk/client"
	"github.com/cosmos/cosmos-sdk/client/tx"
	sdk "github.com/cosmos/cosmos-sdk/types"
	servertypes "github.com/cosmos/cosmos-sdk/server/types"
	banktypes "github.com/cosmos/cosmos-sdk/x/bank/types"
	"github.com/spf13/cast"
)

// ─── Config ──────────────────────────────────────────────────────────────────

// FaucetConfig is embedded into CustomAppConfig (app.toml [faucet] section).
type FaucetConfig struct {
	Enable          bool   `mapstructure:"enable"`
	KeyName         string `mapstructure:"key-name"`
	Amount          int64  `mapstructure:"amount"`
	Denom           string `mapstructure:"denom"`
	GasPrice        string `mapstructure:"gas-price"`
	Gas             uint64 `mapstructure:"gas"`
	CooldownSeconds int64  `mapstructure:"cooldown-seconds"`
}

// DefaultFaucetConfig returns sensible testnet defaults. Disabled by default.
func DefaultFaucetConfig() FaucetConfig {
	return FaucetConfig{
		Enable:          false,
		KeyName:         "faucet",
		Amount:          10_000_000,
		Denom:           "uthiol",
		GasPrice:        "0.025uthiol",
		Gas:             200_000,
		CooldownSeconds: 86400,
	}
}

// ReadFaucetConfig reads faucet config from AppOptions (app.toml via viper).
func ReadFaucetConfig(appOpts servertypes.AppOptions) FaucetConfig {
	cfg := DefaultFaucetConfig()
	if v := appOpts.Get("faucet.enable"); v != nil {
		cfg.Enable = cast.ToBool(v)
	}
	if v := appOpts.Get("faucet.key-name"); v != nil {
		cfg.KeyName = cast.ToString(v)
	}
	if v := appOpts.Get("faucet.amount"); v != nil {
		cfg.Amount = cast.ToInt64(v)
	}
	if v := appOpts.Get("faucet.denom"); v != nil {
		cfg.Denom = cast.ToString(v)
	}
	if v := appOpts.Get("faucet.gas-price"); v != nil {
		cfg.GasPrice = cast.ToString(v)
	}
	if v := appOpts.Get("faucet.gas"); v != nil {
		cfg.Gas = cast.ToUint64(v)
	}
	if v := appOpts.Get("faucet.cooldown-seconds"); v != nil {
		cfg.CooldownSeconds = cast.ToInt64(v)
	}
	return cfg
}

// FaucetConfigTemplate is appended to the app.toml template in root.go.
const FaucetConfigTemplate = `
###############################################################################
###                         Faucet Configuration                            ###
###############################################################################

[faucet]
# Enable the faucet endpoint on the REST API server (port 1317).
# Only enable on testnets. Mainnet should leave this false.
enable = {{ .FaucetConfig.Enable }}

# Name of the key in the node keyring used to sign faucet transactions.
key-name = "{{ .FaucetConfig.KeyName }}"

# Tokens sent per request, in base denom micro-units (e.g. 10000000 = 10 uthiol).
amount = {{ .FaucetConfig.Amount }}

# Coin denomination (e.g. uthiol).
denom = "{{ .FaucetConfig.Denom }}"

# Gas price for faucet transactions (e.g. 0.025uthiol).
gas-price = "{{ .FaucetConfig.GasPrice }}"

# Gas limit per faucet transaction.
gas = {{ .FaucetConfig.Gas }}

# Per-address cooldown in seconds between allowed requests (default 86400 = 24 h).
cooldown-seconds = {{ .FaucetConfig.CooldownSeconds }}
`

// ─── Handler ─────────────────────────────────────────────────────────────────

type faucetHandler struct {
	clientCtx client.Context
	cfg       FaucetConfig
	rl        *faucetRL
}

type faucetRL struct {
	mu      sync.Mutex
	entries map[string]time.Time
	window  time.Duration
}

func (rl *faucetRL) allow(key string) bool {
	rl.mu.Lock()
	defer rl.mu.Unlock()
	if t, ok := rl.entries[key]; ok && time.Since(t) < rl.window {
		return false
	}
	rl.entries[key] = time.Now()
	return true
}

type faucetResp struct {
	TxHash string `json:"tx_hash,omitempty"`
	Amount string `json:"amount,omitempty"`
	Error  string `json:"error,omitempty"`
}

func newFaucetHandler(clientCtx client.Context, cfg FaucetConfig) *faucetHandler {
	return &faucetHandler{
		clientCtx: clientCtx,
		cfg:       cfg,
		rl: &faucetRL{
			entries: make(map[string]time.Time),
			window:  time.Duration(cfg.CooldownSeconds) * time.Second,
		},
	}
}

func (h *faucetHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Access-Control-Allow-Origin", "*")

	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusOK)
		return
	}

	// Accept address as query param (GET) or in JSON body (POST)
	address := r.URL.Query().Get("address")
	if address == "" {
		var body struct {
			Address string `json:"address"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err == nil {
			address = body.Address
		}
	}

	if address == "" {
		writeJSONResp(w, http.StatusBadRequest, faucetResp{Error: "address required (?address=terp1…)"})
		return
	}

	recipientAddr, err := sdk.AccAddressFromBech32(address)
	if err != nil {
		writeJSONResp(w, http.StatusBadRequest, faucetResp{Error: "invalid address: " + err.Error()})
		return
	}

	if !h.rl.allow(address) {
		writeJSONResp(w, http.StatusTooManyRequests, faucetResp{
			Error: fmt.Sprintf("rate limited — one request per %ds per address", h.cfg.CooldownSeconds),
		})
		return
	}

	txHash, err := h.send(r.Context(), recipientAddr)
	if err != nil {
		// If we rate-limited but the tx failed, give the slot back so they can retry
		h.rl.mu.Lock()
		delete(h.rl.entries, address)
		h.rl.mu.Unlock()
		writeJSONResp(w, http.StatusInternalServerError, faucetResp{Error: err.Error()})
		return
	}

	writeJSONResp(w, http.StatusOK, faucetResp{
		TxHash: txHash,
		Amount: fmt.Sprintf("%d%s", h.cfg.Amount, h.cfg.Denom),
	})
}

func (h *faucetHandler) send(ctx context.Context, recipient sdk.AccAddress) (string, error) {
	keyInfo, err := h.clientCtx.Keyring.Key(h.cfg.KeyName)
	if err != nil {
		return "", fmt.Errorf("faucet key %q not in keyring: %w", h.cfg.KeyName, err)
	}

	faucetAddr, err := keyInfo.GetAddress()
	if err != nil {
		return "", fmt.Errorf("get faucet address: %w", err)
	}

	coins := sdk.NewCoins(sdk.NewCoin(h.cfg.Denom, math.NewInt(h.cfg.Amount)))
	msg := banktypes.NewMsgSend(faucetAddr, recipient, coins)

	clientCtx := h.clientCtx.
		WithFromName(h.cfg.KeyName).
		WithFromAddress(faucetAddr)

	factory := tx.Factory{}.
		WithChainID(clientCtx.ChainID).
		WithKeybase(clientCtx.Keyring).
		WithTxConfig(clientCtx.TxConfig).
		WithAccountRetriever(clientCtx.AccountRetriever).
		WithGas(h.cfg.Gas).
		WithGasPrices(h.cfg.GasPrice)

	factory, err = factory.Prepare(clientCtx)
	if err != nil {
		return "", fmt.Errorf("prepare factory (fetch account/sequence): %w", err)
	}

	txBuilder, err := factory.BuildUnsignedTx(msg)
	if err != nil {
		return "", fmt.Errorf("build tx: %w", err)
	}

	if err := tx.Sign(ctx, factory, h.cfg.KeyName, txBuilder, true); err != nil {
		return "", fmt.Errorf("sign tx: %w", err)
	}

	txBytes, err := clientCtx.TxConfig.TxEncoder()(txBuilder.GetTx())
	if err != nil {
		return "", fmt.Errorf("encode tx: %w", err)
	}

	res, err := clientCtx.BroadcastTx(txBytes)
	if err != nil {
		return "", fmt.Errorf("broadcast: %w", err)
	}
	if res.Code != 0 {
		return "", fmt.Errorf("tx failed (code %d): %s", res.Code, res.RawLog)
	}

	return res.TxHash, nil
}

func writeJSONResp(w http.ResponseWriter, code int, v interface{}) {
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
