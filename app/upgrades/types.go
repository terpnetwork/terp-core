package upgrades

import (
	"strings"

	tmproto "github.com/cometbft/cometbft/proto/tendermint/types"

	store "cosmossdk.io/store/types"
	upgradetypes "cosmossdk.io/x/upgrade/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/module"

	"github.com/terpnetwork/terp-core/v4/app/keepers"
)

// BaseAppParamManager defines an interrace that BaseApp is expected to fullfil
// that allows upgrade handlers to modify BaseApp parameters.
type BaseAppParamManager interface {
	GetConsensusParams(ctx sdk.Context) tmproto.ConsensusParams
	StoreConsensusParams(ctx sdk.Context, cp tmproto.ConsensusParams) error
}

// Upgrade defines a struct containing necessary fields that a SoftwareUpgradeProposal
// must have written, in order for the state migration to go smoothly.
// An upgrade must implement this struct, and then set it in the app.go.
// The app.go will then define the handler.
type Upgrade struct {
	// Upgrade version name, for the upgrade handler, e.g. `v7`
	UpgradeName string

	// CreateUpgradeHandler defines the function that creates an upgrade handler
	CreateUpgradeHandler func(*module.Manager, module.Configurator, BaseAppParamManager, *keepers.AppKeepers) upgradetypes.UpgradeHandler

	// Store upgrades, should be used for any new modules introduced, new modules deleted, or store names renamed.
	StoreUpgrades store.StoreUpgrades
}

func GetChainsDenomToken(chainID string) string {
	if strings.HasPrefix(chainID, "90u-") {
		return "uterpx"
	}
	return "uterp"
}

func GetChainsFeeDenomToken(chainID string) string {
	if strings.HasPrefix(chainID, "90u-") {
		return "uthiolx"
	}
	return "uthiol"
}
