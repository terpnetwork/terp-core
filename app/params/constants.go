package params

const (
	AccountAddressPrefix = "terp"
	HumanCoinUnit        = "terp"
	BaseCoinUnit         = "uterp"
	DefaultNodeHomeDir   = ".terpd"
	TerpExponent         = 6

	DefaultBondDenom = BaseCoinUnit

	// Bech32PrefixAccAddr defines the Bech32 prefix of an account's address.
	AppName = "Terp-Core: Node and Validator Software For Terp Network"
	// Name defines the application name of Terp network.
	Name = "terp"

	// BondDenom defines the native staking token denomination.
	BondDenom = "uterp"

	// DisplayBondDenom defines the name, symbol, and display value of the Terp token.
	DisplayBondDenom = "TERP"

	// BondDenom defines the native gas token denomination.
	GasDenom = "uthiol"

	// DisplayGasDenom defines the name, symbol, and display value of the Thiol token.
	DisplayGasDenom = "THIOL"

	// DefaultGasLimit - set to the same value as cosmos-sdk flags.DefaultGasLimit
	// this value is currently only used in tests.
	DefaultGasLimit = 200000

	// Default simulation operation weights for messages and gov proposals
	DefaultWeightMsgSend                        int = 100
	DefaultWeightMsgMultiSend                   int = 10
	DefaultWeightMsgSetWithdrawAddress          int = 50
	DefaultWeightMsgWithdrawDelegationReward    int = 50
	DefaultWeightMsgWithdrawValidatorCommission int = 50
	DefaultWeightMsgFundCommunityPool           int = 50
	DefaultWeightMsgDeposit                     int = 100
	DefaultWeightMsgVote                        int = 67
	DefaultWeightMsgUnjail                      int = 100
	DefaultWeightMsgCreateValidator             int = 100
	DefaultWeightMsgEditValidator               int = 5
	DefaultWeightMsgDelegate                    int = 100
	DefaultWeightMsgUndelegate                  int = 100
	DefaultWeightMsgBeginRedelegate             int = 100

	DefaultWeightCommunitySpendProposal int = 5
	DefaultWeightTextProposal           int = 5
	DefaultWeightParamChangeProposal    int = 5

	DefaultWeightMsgStoreCode           int = 50
	DefaultWeightMsgInstantiateContract int = 100
	DefaultWeightMsgExecuteContract     int = 100
	DefaultWeightMsgUpdateAdmin         int = 25
	DefaultWeightMsgClearAdmin          int = 10
	DefaultWeightMsgMigrateContract     int = 50

	DefaultWeightStoreCodeProposal                   int = 5
	DefaultWeightInstantiateContractProposal         int = 5
	DefaultWeightUpdateAdminProposal                 int = 5
	DefaultWeightExecuteContractProposal             int = 5
	DefaultWeightClearAdminProposal                  int = 5
	DefaultWeightMigrateContractProposal             int = 5
	DefaultWeightSudoContractProposal                int = 5
	DefaultWeightPinCodesProposal                    int = 5
	DefaultWeightUnpinCodesProposal                  int = 5
	DefaultWeightUpdateInstantiateConfigProposal     int = 5
	DefaultWeightStoreAndInstantiateContractProposal int = 5

	// Token Factory Weights
	DefaultWeightMsgCreateDenom      int = 100
	DefaultWeightMsgMint             int = 100
	DefaultWeightMsgBurn             int = 100
	DefaultWeightMsgChangeAdmin      int = 100
	DefaultWeightMsgSetDenomMetadata int = 100
	DefaultWeightMsgForceTransfer    int = 100
)
