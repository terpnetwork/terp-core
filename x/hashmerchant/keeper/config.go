package keeper

import (
	"os"
	"time"

	"github.com/spf13/cast"

	servertypes "github.com/cosmos/cosmos-sdk/server/types"
)

// HashMerchantConfig holds node-local configuration for the hashmerchant module.
// Populated from app.toml [hashmerchant] section with env var overrides.
type HashMerchantConfig struct {
	// SidecarURL is the base URL of the hashmerchant sidecar service.
	// Empty means no sidecar (empty vote extensions — backwards compatible).
	SidecarURL string `mapstructure:"sidecar-url"`

	// SidecarTimeout is the HTTP timeout for sidecar requests.
	SidecarTimeout time.Duration `mapstructure:"sidecar-timeout"`
}

// DefaultConfig returns a HashMerchantConfig with sensible defaults.
func DefaultConfig() HashMerchantConfig {
	return HashMerchantConfig{
		SidecarURL:     "",
		SidecarTimeout: time.Second,
	}
}

// ReadConfig reads hashmerchant config from AppOptions (app.toml) with
// env var overrides. HASHMERCHANT_SIDECAR_URL takes precedence over app.toml.
func ReadConfig(appOpts servertypes.AppOptions) HashMerchantConfig {
	cfg := DefaultConfig()

	if v := appOpts.Get("hashmerchant.sidecar-url"); v != nil {
		cfg.SidecarURL = cast.ToString(v)
	}
	if v := appOpts.Get("hashmerchant.sidecar-timeout"); v != nil {
		cfg.SidecarTimeout = cast.ToDuration(v)
	}
	if cfg.SidecarTimeout == 0 {
		cfg.SidecarTimeout = time.Second
	}

	// Env var override — node operators can set this without editing app.toml.
	if envURL := os.Getenv("HASHMERCHANT_SIDECAR_URL"); envURL != "" {
		cfg.SidecarURL = envURL
	}

	return cfg
}
