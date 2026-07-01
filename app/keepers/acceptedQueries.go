package keepers

import (
	"github.com/cosmos/gogoproto/proto"
	wasmlctypes "github.com/cosmos/ibc-go/modules/light-clients/08-wasm/v10/types"
	icacontrollertypes "github.com/cosmos/ibc-go/v10/modules/apps/27-interchain-accounts/controller/types"
	ibctransfertypes "github.com/cosmos/ibc-go/v10/modules/apps/transfer/types"
	ibcclienttypes "github.com/cosmos/ibc-go/v10/modules/core/02-client/types"
	ibcconnectiontypes "github.com/cosmos/ibc-go/v10/modules/core/03-connection/types"
	ibcchanneltypes "github.com/cosmos/ibc-go/v10/modules/core/04-channel/types"

	ibcv2client "github.com/cosmos/ibc-go/v10/modules/core/02-client/v2/types"
	ibcv2channel "github.com/cosmos/ibc-go/v10/modules/core/04-channel/v2/types"

	storetypes "cosmossdk.io/store/types"
	authtypes "github.com/cosmos/cosmos-sdk/x/auth/types"
	banktypes "github.com/cosmos/cosmos-sdk/x/bank/types"
	distrtypes "github.com/cosmos/cosmos-sdk/x/distribution/types"
	govv1 "github.com/cosmos/cosmos-sdk/x/gov/types/v1"
	stakingtypes "github.com/cosmos/cosmos-sdk/x/staking/types"
)

// QuerierWrapper is a local wrapper around BaseApp that exports only the Queryable interface.
// This is used to pass the baseApp to Async ICQ without exposing all methods
type QuerierWrapper struct {
	querier storetypes.Queryable
}

var _ storetypes.Queryable = QuerierWrapper{}

func NewQuerierWrapper(querier storetypes.Queryable) QuerierWrapper {
	return QuerierWrapper{querier: querier}
}

func (q QuerierWrapper) Query(req *storetypes.RequestQuery) (*storetypes.ResponseQuery, error) {
	return q.querier.Query(req)
}

func AcceptedQueries() map[string]func() proto.Message {
	return map[string]func() proto.Message{
		// ibc
		"/ibc.core.client.v1.Query/ClientState":         func() proto.Message { return &ibcclienttypes.QueryClientStateResponse{} },
		"/ibc.core.client.v1.Query/ConsensusState":      func() proto.Message { return &ibcclienttypes.QueryConsensusStateResponse{} },
		"/ibc.core.connection.v1.Query/Connection":      func() proto.Message { return &ibcconnectiontypes.QueryConnectionResponse{} },
		"/ibc.core.channel.v1.Query/ChannelClientState": func() proto.Message { return &ibcchanneltypes.QueryChannelClientStateResponse{} },

		// ibcv2
		"/ibc.core.client.v2.Query/Config":                 func() proto.Message { return &ibcv2client.QueryConfigResponse{} },
		"/ibc.core.client.v2.Query/CounterpartyInfo":       func() proto.Message { return &ibcv2client.QueryCounterpartyInfoResponse{} },
		"/ibc.core.channel.v2.Query/QueryNextSequenceSend": func() proto.Message { return &ibcv2channel.QueryNextSequenceSendResponse{} },

		// interchain accounts
		"/ibc.applications.interchain_accounts.controller.v1.Query/InterchainAccount": func() proto.Message { return &icacontrollertypes.QueryInterchainAccountResponse{} },

		"/ibc.lightclients.wasm.v1.Query/Checksums":         func() proto.Message { return &wasmlctypes.QueryChecksumsResponse{} },
		"/ibc.lightclients.attestations.v1.Query/Checksums": func() proto.Message { return &wasmlctypes.QueryChecksumsResponse{} },

		// transfer
		"/ibc.applications.transfer.v1.Query/Denom":         func() proto.Message { return &ibctransfertypes.QueryDenomResponse{} },
		"/ibc.applications.transfer.v1.Query/EscrowAddress": func() proto.Message { return &ibctransfertypes.QueryEscrowAddressResponse{} },

		// auth
		"/cosmos.auth.v1beta1.Query/Account": func() proto.Message { return &authtypes.QueryAccountResponse{} },
		"/cosmos.auth.v1beta1.Query/Params":  func() proto.Message { return &authtypes.QueryParamsResponse{} },

		// bank
		"/cosmos.bank.v1beta1.Query/Balance":       func() proto.Message { return &banktypes.QueryBalanceResponse{} },
		"/cosmos.bank.v1beta1.Query/DenomMetadata": func() proto.Message { return &banktypes.QueryDenomsMetadataResponse{} },
		"/cosmos.bank.v1beta1.Query/Params":        func() proto.Message { return &banktypes.QueryParamsResponse{} },
		"/cosmos.bank.v1beta1.Query/SupplyOf":      func() proto.Message { return &banktypes.QuerySupplyOfResponse{} },
		// added all balances query, since v3 cosmwasm removed native support
		"/cosmos.bank.v1beta1.Query/AllBalances": func() proto.Message { return &banktypes.QueryAllBalancesResponse{} },

		// governance
		"/cosmos.gov.v1beta1.Query/Vote": func() proto.Message { return &govv1.QueryVoteResponse{} },

		// distribution
		"/cosmos.distribution.v1beta1.Query/DelegationRewards": func() proto.Message { return &distrtypes.QueryDelegationRewardsResponse{} },

		// staking
		"/cosmos.staking.v1beta1.Query/Delegation":          func() proto.Message { return &stakingtypes.QueryDelegationResponse{} },
		"/cosmos.staking.v1beta1.Query/Redelegations":       func() proto.Message { return &stakingtypes.QueryRedelegationsResponse{} },
		"/cosmos.staking.v1beta1.Query/UnbondingDelegation": func() proto.Message { return &stakingtypes.QueryUnbondingDelegationResponse{} },
		"/cosmos.staking.v1beta1.Query/Validator":           func() proto.Message { return &stakingtypes.QueryValidatorResponse{} },
		"/cosmos.staking.v1beta1.Query/Params":              func() proto.Message { return &stakingtypes.QueryParamsResponse{} },
		"/cosmos.staking.v1beta1.Query/Pool":                func() proto.Message { return &stakingtypes.QueryPoolResponse{} },
	}
}
