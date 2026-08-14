package v520

import (
	store "github.com/cosmos/cosmos-sdk/store/v2/types"
	distrtypes "github.com/cosmos/cosmos-sdk/x/distribution/types"
	"github.com/terpnetwork/terp-core/v6/app/upgrades"
)

const (
	green  = "\033[32m"
	yellow = "\033[33m"
	red    = "\033[31m"
	reset  = "\033[0m"
)

const UpgradeName = "v520"

var Upgrade = upgrades.Upgrade{
	UpgradeName:          UpgradeName,
	CreateUpgradeHandler: CreateV520UpgradeHandler,
	StoreUpgrades: store.StoreUpgrades{
		Added: []string{},
	},
}

const (
	PatchVal1 = "terpvaloper1rwyn6w46u3067enhpdceqasg2um8dddt6tehsv"
)

type ConditionalJSON struct {
	PatchDelegationCount     uint
	PatchedHistRewards       []distrtypes.ValidatorHistoricalRewardsRecord
	ZeroSharesDelegation     []ZeroSharesDelegation
	PatchedDelegation        []PatchedDelegation
	NilDelegationCalculation []NilDelegationCalculation
	DistSlashStore           DistrSlashObject
}

type DistrSlashObject struct {
	SlashEventCount uint64               `json:"total_slashes"`
	DistrSlashEvent []map[string][]Slash `json:"events"`
}
type DistrSlashEvent struct {
	Val             string  `json:"val_addr"`
	SlashEventCount uint64  `json:"total"`
	Slashes         []Slash `json:"slash_events"`
}
type Slash struct {
	Height   uint64 `json:"height"`
	Fraction string `json:"fraction"`
	Period   uint64 `json:"period"`
}

type ZeroSharesDelegation struct {
	OperatorAddress  string `json:"val_addr"`
	DelegatorAddress string `json:"del_addr"`
}
type PatchedDelegation struct {
	OperatorAddress   string `json:"val_addr"`
	DelegatorAddress  string `json:"del_addr"`
	PatchedDelegation string `json:"patch"`
}
type NilDelegationCalculation struct {
	OperatorAddress  string `json:"val_addr"`
	DelegatorAddress string `json:"del_addr"`
}
