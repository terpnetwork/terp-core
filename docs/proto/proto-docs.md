<!-- This file is auto-generated. Please do not modify it yourself. -->
# Protobuf Documentation
<a name="top"></a>

## Table of Contents

- [cosmwasm/tokenfactory/v1beta1/authorityMetadata.proto](#cosmwasm/tokenfactory/v1beta1/authorityMetadata.proto)
    - [DenomAuthorityMetadata](#cosmwasm.tokenfactory.v1beta1.DenomAuthorityMetadata)
  
- [cosmwasm/tokenfactory/v1beta1/params.proto](#cosmwasm/tokenfactory/v1beta1/params.proto)
    - [Params](#cosmwasm.tokenfactory.v1beta1.Params)
  
- [cosmwasm/tokenfactory/v1beta1/genesis.proto](#cosmwasm/tokenfactory/v1beta1/genesis.proto)
    - [GenesisDenom](#cosmwasm.tokenfactory.v1beta1.GenesisDenom)
    - [GenesisState](#cosmwasm.tokenfactory.v1beta1.GenesisState)
  
<<<<<<< HEAD
- [cosmwasm/wasm/v1/genesis.proto](#cosmwasm/wasm/v1/genesis.proto)
    - [Code](#cosmwasm.wasm.v1.Code)
    - [Contract](#cosmwasm.wasm.v1.Contract)
    - [GenesisState](#cosmwasm.wasm.v1.GenesisState)
    - [Sequence](#cosmwasm.wasm.v1.Sequence)
  
- [cosmwasm/wasm/v1/ibc.proto](#cosmwasm/wasm/v1/ibc.proto)
    - [MsgIBCCloseChannel](#cosmwasm.wasm.v1.MsgIBCCloseChannel)
    - [MsgIBCSend](#cosmwasm.wasm.v1.MsgIBCSend)
    - [MsgIBCSendResponse](#cosmwasm.wasm.v1.MsgIBCSendResponse)
  
- [cosmwasm/wasm/v1/proposal.proto](#cosmwasm/wasm/v1/proposal.proto)
    - [AccessConfigUpdate](#cosmwasm.wasm.v1.AccessConfigUpdate)
    - [ClearAdminProposal](#cosmwasm.wasm.v1.ClearAdminProposal)
    - [ExecuteContractProposal](#cosmwasm.wasm.v1.ExecuteContractProposal)
    - [InstantiateContract2Proposal](#cosmwasm.wasm.v1.InstantiateContract2Proposal)
    - [InstantiateContractProposal](#cosmwasm.wasm.v1.InstantiateContractProposal)
    - [MigrateContractProposal](#cosmwasm.wasm.v1.MigrateContractProposal)
    - [PinCodesProposal](#cosmwasm.wasm.v1.PinCodesProposal)
    - [StoreAndInstantiateContractProposal](#cosmwasm.wasm.v1.StoreAndInstantiateContractProposal)
    - [StoreCodeProposal](#cosmwasm.wasm.v1.StoreCodeProposal)
    - [SudoContractProposal](#cosmwasm.wasm.v1.SudoContractProposal)
    - [UnpinCodesProposal](#cosmwasm.wasm.v1.UnpinCodesProposal)
    - [UpdateAdminProposal](#cosmwasm.wasm.v1.UpdateAdminProposal)
    - [UpdateInstantiateConfigProposal](#cosmwasm.wasm.v1.UpdateInstantiateConfigProposal)
  
- [cosmwasm/wasm/v1/query.proto](#cosmwasm/wasm/v1/query.proto)
    - [CodeInfoResponse](#cosmwasm.wasm.v1.CodeInfoResponse)
    - [QueryAllContractStateRequest](#cosmwasm.wasm.v1.QueryAllContractStateRequest)
    - [QueryAllContractStateResponse](#cosmwasm.wasm.v1.QueryAllContractStateResponse)
    - [QueryCodeRequest](#cosmwasm.wasm.v1.QueryCodeRequest)
    - [QueryCodeResponse](#cosmwasm.wasm.v1.QueryCodeResponse)
    - [QueryCodesRequest](#cosmwasm.wasm.v1.QueryCodesRequest)
    - [QueryCodesResponse](#cosmwasm.wasm.v1.QueryCodesResponse)
    - [QueryContractHistoryRequest](#cosmwasm.wasm.v1.QueryContractHistoryRequest)
    - [QueryContractHistoryResponse](#cosmwasm.wasm.v1.QueryContractHistoryResponse)
    - [QueryContractInfoRequest](#cosmwasm.wasm.v1.QueryContractInfoRequest)
    - [QueryContractInfoResponse](#cosmwasm.wasm.v1.QueryContractInfoResponse)
    - [QueryContractsByCodeRequest](#cosmwasm.wasm.v1.QueryContractsByCodeRequest)
    - [QueryContractsByCodeResponse](#cosmwasm.wasm.v1.QueryContractsByCodeResponse)
    - [QueryContractsByCreatorRequest](#cosmwasm.wasm.v1.QueryContractsByCreatorRequest)
    - [QueryContractsByCreatorResponse](#cosmwasm.wasm.v1.QueryContractsByCreatorResponse)
    - [QueryParamsRequest](#cosmwasm.wasm.v1.QueryParamsRequest)
    - [QueryParamsResponse](#cosmwasm.wasm.v1.QueryParamsResponse)
    - [QueryPinnedCodesRequest](#cosmwasm.wasm.v1.QueryPinnedCodesRequest)
    - [QueryPinnedCodesResponse](#cosmwasm.wasm.v1.QueryPinnedCodesResponse)
    - [QueryRawContractStateRequest](#cosmwasm.wasm.v1.QueryRawContractStateRequest)
    - [QueryRawContractStateResponse](#cosmwasm.wasm.v1.QueryRawContractStateResponse)
    - [QuerySmartContractStateRequest](#cosmwasm.wasm.v1.QuerySmartContractStateRequest)
    - [QuerySmartContractStateResponse](#cosmwasm.wasm.v1.QuerySmartContractStateResponse)
  
    - [Query](#cosmwasm.wasm.v1.Query)
=======
- [cosmwasm/tokenfactory/v1beta1/query.proto](#cosmwasm/tokenfactory/v1beta1/query.proto)
    - [QueryDenomAuthorityMetadataRequest](#cosmwasm.tokenfactory.v1beta1.QueryDenomAuthorityMetadataRequest)
    - [QueryDenomAuthorityMetadataResponse](#cosmwasm.tokenfactory.v1beta1.QueryDenomAuthorityMetadataResponse)
    - [QueryDenomsFromCreatorRequest](#cosmwasm.tokenfactory.v1beta1.QueryDenomsFromCreatorRequest)
    - [QueryDenomsFromCreatorResponse](#cosmwasm.tokenfactory.v1beta1.QueryDenomsFromCreatorResponse)
    - [QueryParamsRequest](#cosmwasm.tokenfactory.v1beta1.QueryParamsRequest)
    - [QueryParamsResponse](#cosmwasm.tokenfactory.v1beta1.QueryParamsResponse)
  
    - [Query](#cosmwasm.tokenfactory.v1beta1.Query)
  
- [cosmwasm/tokenfactory/v1beta1/tx.proto](#cosmwasm/tokenfactory/v1beta1/tx.proto)
    - [MsgBurn](#cosmwasm.tokenfactory.v1beta1.MsgBurn)
    - [MsgBurnResponse](#cosmwasm.tokenfactory.v1beta1.MsgBurnResponse)
    - [MsgChangeAdmin](#cosmwasm.tokenfactory.v1beta1.MsgChangeAdmin)
    - [MsgChangeAdminResponse](#cosmwasm.tokenfactory.v1beta1.MsgChangeAdminResponse)
    - [MsgCreateDenom](#cosmwasm.tokenfactory.v1beta1.MsgCreateDenom)
    - [MsgCreateDenomResponse](#cosmwasm.tokenfactory.v1beta1.MsgCreateDenomResponse)
    - [MsgMint](#cosmwasm.tokenfactory.v1beta1.MsgMint)
    - [MsgMintResponse](#cosmwasm.tokenfactory.v1beta1.MsgMintResponse)
    - [MsgSetDenomMetadata](#cosmwasm.tokenfactory.v1beta1.MsgSetDenomMetadata)
    - [MsgSetDenomMetadataResponse](#cosmwasm.tokenfactory.v1beta1.MsgSetDenomMetadataResponse)
  
    - [Msg](#cosmwasm.tokenfactory.v1beta1.Msg)
>>>>>>> notional/release/v0.30.0-sdk-v0.46.x
  
- [cosmwasm/wasm/v1/tx.proto](#cosmwasm/wasm/v1/tx.proto)
    - [MsgClearAdmin](#cosmwasm.wasm.v1.MsgClearAdmin)
    - [MsgClearAdminResponse](#cosmwasm.wasm.v1.MsgClearAdminResponse)
    - [MsgExecuteContract](#cosmwasm.wasm.v1.MsgExecuteContract)
    - [MsgExecuteContractResponse](#cosmwasm.wasm.v1.MsgExecuteContractResponse)
    - [MsgInstantiateContract](#cosmwasm.wasm.v1.MsgInstantiateContract)
    - [MsgInstantiateContract2](#cosmwasm.wasm.v1.MsgInstantiateContract2)
    - [MsgInstantiateContract2Response](#cosmwasm.wasm.v1.MsgInstantiateContract2Response)
    - [MsgInstantiateContractResponse](#cosmwasm.wasm.v1.MsgInstantiateContractResponse)
    - [MsgMigrateContract](#cosmwasm.wasm.v1.MsgMigrateContract)
    - [MsgMigrateContractResponse](#cosmwasm.wasm.v1.MsgMigrateContractResponse)
    - [MsgStoreCode](#cosmwasm.wasm.v1.MsgStoreCode)
    - [MsgStoreCodeResponse](#cosmwasm.wasm.v1.MsgStoreCodeResponse)
    - [MsgUpdateAdmin](#cosmwasm.wasm.v1.MsgUpdateAdmin)
    - [MsgUpdateAdminResponse](#cosmwasm.wasm.v1.MsgUpdateAdminResponse)
    - [MsgUpdateInstantiateConfig](#cosmwasm.wasm.v1.MsgUpdateInstantiateConfig)
    - [MsgUpdateInstantiateConfigResponse](#cosmwasm.wasm.v1.MsgUpdateInstantiateConfigResponse)
  
    - [Msg](#cosmwasm.wasm.v1.Msg)
  
- [Scalar Value Types](#scalar-value-types)



<a name="cosmwasm/tokenfactory/v1beta1/authorityMetadata.proto"></a>
<p align="right"><a href="#top">Top</a></p>

## cosmwasm/tokenfactory/v1beta1/authorityMetadata.proto



<a name="cosmwasm.tokenfactory.v1beta1.DenomAuthorityMetadata"></a>

### DenomAuthorityMetadata
DenomAuthorityMetadata specifies metadata for addresses that have specific
capabilities over a token factory denom. Right now there is only one Admin
permission, but is planned to be extended to the future.


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `admin` | [string](#string) |  | Can be empty for no admin, or a valid osmosis address |





 <!-- end messages -->

 <!-- end enums -->

 <!-- end HasExtensions -->

 <!-- end services -->



<a name="cosmwasm/tokenfactory/v1beta1/params.proto"></a>
<p align="right"><a href="#top">Top</a></p>

## cosmwasm/tokenfactory/v1beta1/params.proto



<a name="cosmwasm.tokenfactory.v1beta1.Params"></a>

### Params
Params defines the parameters for the tokenfactory module.


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
<<<<<<< HEAD
| `code_upload_access` | [AccessConfig](#cosmwasm.wasm.v1.AccessConfig) |  |  |
| `instantiate_default_permission` | [AccessType](#cosmwasm.wasm.v1.AccessType) |  |  |
=======
| `denom_creation_fee` | [cosmos.base.v1beta1.Coin](#cosmos.base.v1beta1.Coin) | repeated |  |
>>>>>>> notional/release/v0.30.0-sdk-v0.46.x





 <!-- end messages -->

<<<<<<< HEAD

<a name="cosmwasm.wasm.v1.AccessType"></a>

### AccessType
AccessType permission types

| Name | Number | Description |
| ---- | ------ | ----------- |
| ACCESS_TYPE_UNSPECIFIED | 0 | AccessTypeUnspecified placeholder for empty value |
| ACCESS_TYPE_NOBODY | 1 | AccessTypeNobody forbidden |
| ACCESS_TYPE_ONLY_ADDRESS | 2 | AccessTypeOnlyAddress restricted to a single address Deprecated: use AccessTypeAnyOfAddresses instead |
| ACCESS_TYPE_EVERYBODY | 3 | AccessTypeEverybody unrestricted |
| ACCESS_TYPE_ANY_OF_ADDRESSES | 4 | AccessTypeAnyOfAddresses allow any of the addresses |



<a name="cosmwasm.wasm.v1.ContractCodeHistoryOperationType"></a>

### ContractCodeHistoryOperationType
ContractCodeHistoryOperationType actions that caused a code change

| Name | Number | Description |
| ---- | ------ | ----------- |
| CONTRACT_CODE_HISTORY_OPERATION_TYPE_UNSPECIFIED | 0 | ContractCodeHistoryOperationTypeUnspecified placeholder for empty value |
| CONTRACT_CODE_HISTORY_OPERATION_TYPE_INIT | 1 | ContractCodeHistoryOperationTypeInit on chain contract instantiation |
| CONTRACT_CODE_HISTORY_OPERATION_TYPE_MIGRATE | 2 | ContractCodeHistoryOperationTypeMigrate code migration |
| CONTRACT_CODE_HISTORY_OPERATION_TYPE_GENESIS | 3 | ContractCodeHistoryOperationTypeGenesis based on genesis data |


=======
>>>>>>> notional/release/v0.30.0-sdk-v0.46.x
 <!-- end enums -->

 <!-- end HasExtensions -->

 <!-- end services -->



<<<<<<< HEAD
<a name="cosmwasm/wasm/v1/genesis.proto"></a>
=======
<a name="cosmwasm/tokenfactory/v1beta1/genesis.proto"></a>
>>>>>>> notional/release/v0.30.0-sdk-v0.46.x
<p align="right"><a href="#top">Top</a></p>

## cosmwasm/tokenfactory/v1beta1/genesis.proto



<a name="cosmwasm.tokenfactory.v1beta1.GenesisDenom"></a>

### GenesisDenom
GenesisDenom defines a tokenfactory denom that is defined within genesis
state. The structure contains DenomAuthorityMetadata which defines the
denom's admin.


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `denom` | [string](#string) |  |  |
| `authority_metadata` | [DenomAuthorityMetadata](#cosmwasm.tokenfactory.v1beta1.DenomAuthorityMetadata) |  |  |






<a name="cosmwasm.tokenfactory.v1beta1.GenesisState"></a>

### GenesisState
GenesisState defines the tokenfactory module's genesis state.


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
<<<<<<< HEAD
| `params` | [Params](#cosmwasm.wasm.v1.Params) |  |  |
| `codes` | [Code](#cosmwasm.wasm.v1.Code) | repeated |  |
| `contracts` | [Contract](#cosmwasm.wasm.v1.Contract) | repeated |  |
| `sequences` | [Sequence](#cosmwasm.wasm.v1.Sequence) | repeated |  |






<a name="cosmwasm.wasm.v1.Sequence"></a>

### Sequence
Sequence key and value of an id generation counter


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `id_key` | [bytes](#bytes) |  |  |
| `value` | [uint64](#uint64) |  |  |
=======
| `params` | [Params](#cosmwasm.tokenfactory.v1beta1.Params) |  | params defines the paramaters of the module. |
| `factory_denoms` | [GenesisDenom](#cosmwasm.tokenfactory.v1beta1.GenesisDenom) | repeated |  |
>>>>>>> notional/release/v0.30.0-sdk-v0.46.x





 <!-- end messages -->

 <!-- end enums -->

 <!-- end HasExtensions -->

 <!-- end services -->



<a name="cosmwasm/tokenfactory/v1beta1/query.proto"></a>
<p align="right"><a href="#top">Top</a></p>

## cosmwasm/tokenfactory/v1beta1/query.proto



<a name="cosmwasm.tokenfactory.v1beta1.QueryDenomAuthorityMetadataRequest"></a>

### QueryDenomAuthorityMetadataRequest
QueryDenomAuthorityMetadataRequest defines the request structure for the
DenomAuthorityMetadata gRPC query.


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `denom` | [string](#string) |  |  |






<a name="cosmwasm.tokenfactory.v1beta1.QueryDenomAuthorityMetadataResponse"></a>

### QueryDenomAuthorityMetadataResponse
QueryDenomAuthorityMetadataResponse defines the response structure for the
DenomAuthorityMetadata gRPC query.


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `authority_metadata` | [DenomAuthorityMetadata](#cosmwasm.tokenfactory.v1beta1.DenomAuthorityMetadata) |  |  |





<<<<<<< HEAD

<a name="cosmwasm.wasm.v1.MsgIBCSendResponse"></a>

### MsgIBCSendResponse
MsgIBCSendResponse


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `sequence` | [uint64](#uint64) |  | Sequence number of the IBC packet sent |





 <!-- end messages -->
=======
>>>>>>> notional/release/v0.30.0-sdk-v0.46.x

<a name="cosmwasm.tokenfactory.v1beta1.QueryDenomsFromCreatorRequest"></a>

### QueryDenomsFromCreatorRequest
QueryDenomsFromCreatorRequest defines the request structure for the
DenomsFromCreator gRPC query.


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
<<<<<<< HEAD
| `code_id` | [uint64](#uint64) |  | CodeID is the reference to the stored WASM code to be updated |
| `instantiate_permission` | [AccessConfig](#cosmwasm.wasm.v1.AccessConfig) |  | InstantiatePermission to apply to the set of code ids |






<a name="cosmwasm.wasm.v1.ClearAdminProposal"></a>

### ClearAdminProposal
ClearAdminProposal gov proposal content type to clear the admin of a
contract.


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `title` | [string](#string) |  | Title is a short summary |
| `description` | [string](#string) |  | Description is a human readable text |
| `contract` | [string](#string) |  | Contract is the address of the smart contract |






<a name="cosmwasm.wasm.v1.ExecuteContractProposal"></a>

### ExecuteContractProposal
ExecuteContractProposal gov proposal content type to call execute on a
contract.


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `title` | [string](#string) |  | Title is a short summary |
| `description` | [string](#string) |  | Description is a human readable text |
| `run_as` | [string](#string) |  | RunAs is the address that is passed to the contract's environment as sender |
| `contract` | [string](#string) |  | Contract is the address of the smart contract |
| `msg` | [bytes](#bytes) |  | Msg json encoded message to be passed to the contract as execute |
| `funds` | [cosmos.base.v1beta1.Coin](#cosmos.base.v1beta1.Coin) | repeated | Funds coins that are transferred to the contract on instantiation |






<a name="cosmwasm.wasm.v1.InstantiateContract2Proposal"></a>

### InstantiateContract2Proposal
InstantiateContract2Proposal gov proposal content type to instantiate
contract 2


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `title` | [string](#string) |  | Title is a short summary |
| `description` | [string](#string) |  | Description is a human readable text |
| `run_as` | [string](#string) |  | RunAs is the address that is passed to the contract's enviroment as sender |
| `admin` | [string](#string) |  | Admin is an optional address that can execute migrations |
| `code_id` | [uint64](#uint64) |  | CodeID is the reference to the stored WASM code |
| `label` | [string](#string) |  | Label is optional metadata to be stored with a constract instance. |
| `msg` | [bytes](#bytes) |  | Msg json encode message to be passed to the contract on instantiation |
| `funds` | [cosmos.base.v1beta1.Coin](#cosmos.base.v1beta1.Coin) | repeated | Funds coins that are transferred to the contract on instantiation |
| `salt` | [bytes](#bytes) |  | Salt is an arbitrary value provided by the sender. Size can be 1 to 64. |
| `fix_msg` | [bool](#bool) |  | FixMsg include the msg value into the hash for the predictable address. Default is false |






<a name="cosmwasm.wasm.v1.InstantiateContractProposal"></a>

### InstantiateContractProposal
InstantiateContractProposal gov proposal content type to instantiate a
contract.


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `title` | [string](#string) |  | Title is a short summary |
| `description` | [string](#string) |  | Description is a human readable text |
| `run_as` | [string](#string) |  | RunAs is the address that is passed to the contract's environment as sender |
| `admin` | [string](#string) |  | Admin is an optional address that can execute migrations |
| `code_id` | [uint64](#uint64) |  | CodeID is the reference to the stored WASM code |
| `label` | [string](#string) |  | Label is optional metadata to be stored with a constract instance. |
| `msg` | [bytes](#bytes) |  | Msg json encoded message to be passed to the contract on instantiation |
| `funds` | [cosmos.base.v1beta1.Coin](#cosmos.base.v1beta1.Coin) | repeated | Funds coins that are transferred to the contract on instantiation |






<a name="cosmwasm.wasm.v1.MigrateContractProposal"></a>

### MigrateContractProposal
MigrateContractProposal gov proposal content type to migrate a contract.


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `title` | [string](#string) |  | Title is a short summary |
| `description` | [string](#string) |  | Description is a human readable text

Note: skipping 3 as this was previously used for unneeded run_as |
| `contract` | [string](#string) |  | Contract is the address of the smart contract |
| `code_id` | [uint64](#uint64) |  | CodeID references the new WASM code |
| `msg` | [bytes](#bytes) |  | Msg json encoded message to be passed to the contract on migration |






<a name="cosmwasm.wasm.v1.PinCodesProposal"></a>

### PinCodesProposal
PinCodesProposal gov proposal content type to pin a set of code ids in the
wasmvm cache.


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `title` | [string](#string) |  | Title is a short summary |
| `description` | [string](#string) |  | Description is a human readable text |
| `code_ids` | [uint64](#uint64) | repeated | CodeIDs references the new WASM codes |






<a name="cosmwasm.wasm.v1.StoreAndInstantiateContractProposal"></a>

### StoreAndInstantiateContractProposal
StoreAndInstantiateContractProposal gov proposal content type to store
and instantiate the contract.


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `title` | [string](#string) |  | Title is a short summary |
| `description` | [string](#string) |  | Description is a human readable text |
| `run_as` | [string](#string) |  | RunAs is the address that is passed to the contract's environment as sender |
| `wasm_byte_code` | [bytes](#bytes) |  | WASMByteCode can be raw or gzip compressed |
| `instantiate_permission` | [AccessConfig](#cosmwasm.wasm.v1.AccessConfig) |  | InstantiatePermission to apply on contract creation, optional |
| `unpin_code` | [bool](#bool) |  | UnpinCode code on upload, optional |
| `admin` | [string](#string) |  | Admin is an optional address that can execute migrations |
| `label` | [string](#string) |  | Label is optional metadata to be stored with a constract instance. |
| `msg` | [bytes](#bytes) |  | Msg json encoded message to be passed to the contract on instantiation |
| `funds` | [cosmos.base.v1beta1.Coin](#cosmos.base.v1beta1.Coin) | repeated | Funds coins that are transferred to the contract on instantiation |
| `source` | [string](#string) |  | Source is the URL where the code is hosted |
| `builder` | [string](#string) |  | Builder is the docker image used to build the code deterministically, used for smart contract verification |
| `code_hash` | [bytes](#bytes) |  | CodeHash is the SHA256 sum of the code outputted by builder, used for smart contract verification |






<a name="cosmwasm.wasm.v1.StoreCodeProposal"></a>

### StoreCodeProposal
StoreCodeProposal gov proposal content type to submit WASM code to the system


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `title` | [string](#string) |  | Title is a short summary |
| `description` | [string](#string) |  | Description is a human readable text |
| `run_as` | [string](#string) |  | RunAs is the address that is passed to the contract's environment as sender |
| `wasm_byte_code` | [bytes](#bytes) |  | WASMByteCode can be raw or gzip compressed |
| `instantiate_permission` | [AccessConfig](#cosmwasm.wasm.v1.AccessConfig) |  | InstantiatePermission to apply on contract creation, optional |
| `unpin_code` | [bool](#bool) |  | UnpinCode code on upload, optional |
| `source` | [string](#string) |  | Source is the URL where the code is hosted |
| `builder` | [string](#string) |  | Builder is the docker image used to build the code deterministically, used for smart contract verification |
| `code_hash` | [bytes](#bytes) |  | CodeHash is the SHA256 sum of the code outputted by builder, used for smart contract verification |






<a name="cosmwasm.wasm.v1.SudoContractProposal"></a>

### SudoContractProposal
SudoContractProposal gov proposal content type to call sudo on a contract.


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `title` | [string](#string) |  | Title is a short summary |
| `description` | [string](#string) |  | Description is a human readable text |
| `contract` | [string](#string) |  | Contract is the address of the smart contract |
| `msg` | [bytes](#bytes) |  | Msg json encoded message to be passed to the contract as sudo |






<a name="cosmwasm.wasm.v1.UnpinCodesProposal"></a>

### UnpinCodesProposal
UnpinCodesProposal gov proposal content type to unpin a set of code ids in
the wasmvm cache.


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `title` | [string](#string) |  | Title is a short summary |
| `description` | [string](#string) |  | Description is a human readable text |
| `code_ids` | [uint64](#uint64) | repeated | CodeIDs references the WASM codes |






<a name="cosmwasm.wasm.v1.UpdateAdminProposal"></a>

### UpdateAdminProposal
UpdateAdminProposal gov proposal content type to set an admin for a contract.


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `title` | [string](#string) |  | Title is a short summary |
| `description` | [string](#string) |  | Description is a human readable text |
| `new_admin` | [string](#string) |  | NewAdmin address to be set |
| `contract` | [string](#string) |  | Contract is the address of the smart contract |






<a name="cosmwasm.wasm.v1.UpdateInstantiateConfigProposal"></a>

### UpdateInstantiateConfigProposal
UpdateInstantiateConfigProposal gov proposal content type to update
instantiate config to a  set of code ids.


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `title` | [string](#string) |  | Title is a short summary |
| `description` | [string](#string) |  | Description is a human readable text |
| `access_config_updates` | [AccessConfigUpdate](#cosmwasm.wasm.v1.AccessConfigUpdate) | repeated | AccessConfigUpdate contains the list of code ids and the access config to be applied. |





 <!-- end messages -->

 <!-- end enums -->

 <!-- end HasExtensions -->

 <!-- end services -->



<a name="cosmwasm/wasm/v1/query.proto"></a>
<p align="right"><a href="#top">Top</a></p>

## cosmwasm/wasm/v1/query.proto



<a name="cosmwasm.wasm.v1.CodeInfoResponse"></a>

### CodeInfoResponse
CodeInfoResponse contains code meta data from CodeInfo


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `code_id` | [uint64](#uint64) |  | id for legacy support |
=======
>>>>>>> notional/release/v0.30.0-sdk-v0.46.x
| `creator` | [string](#string) |  |  |






<a name="cosmwasm.tokenfactory.v1beta1.QueryDenomsFromCreatorResponse"></a>

### QueryDenomsFromCreatorResponse
QueryDenomsFromCreatorRequest defines the response structure for the
DenomsFromCreator gRPC query.


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `denoms` | [string](#string) | repeated |  |






<a name="cosmwasm.tokenfactory.v1beta1.QueryParamsRequest"></a>

### QueryParamsRequest
QueryParamsRequest is the request type for the Query/Params RPC method.






<a name="cosmwasm.tokenfactory.v1beta1.QueryParamsResponse"></a>

### QueryParamsResponse
QueryParamsResponse is the response type for the Query/Params RPC method.


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `params` | [Params](#cosmwasm.tokenfactory.v1beta1.Params) |  | params defines the parameters of the module. |





 <!-- end messages -->

 <!-- end enums -->

 <!-- end HasExtensions -->


<a name="cosmwasm.tokenfactory.v1beta1.Query"></a>

### Query
Query defines the gRPC querier service.

| Method Name | Request Type | Response Type | Description | HTTP Verb | Endpoint |
| ----------- | ------------ | ------------- | ------------| ------- | -------- |
| `Params` | [QueryParamsRequest](#cosmwasm.tokenfactory.v1beta1.QueryParamsRequest) | [QueryParamsResponse](#cosmwasm.tokenfactory.v1beta1.QueryParamsResponse) | Params defines a gRPC query method that returns the tokenfactory module's parameters. | GET|/osmosis/tokenfactory/v1beta1/params|
| `DenomAuthorityMetadata` | [QueryDenomAuthorityMetadataRequest](#cosmwasm.tokenfactory.v1beta1.QueryDenomAuthorityMetadataRequest) | [QueryDenomAuthorityMetadataResponse](#cosmwasm.tokenfactory.v1beta1.QueryDenomAuthorityMetadataResponse) | DenomAuthorityMetadata defines a gRPC query method for fetching DenomAuthorityMetadata for a particular denom. | GET|/osmosis/tokenfactory/v1beta1/denoms/{denom}/authority_metadata|
| `DenomsFromCreator` | [QueryDenomsFromCreatorRequest](#cosmwasm.tokenfactory.v1beta1.QueryDenomsFromCreatorRequest) | [QueryDenomsFromCreatorResponse](#cosmwasm.tokenfactory.v1beta1.QueryDenomsFromCreatorResponse) | DenomsFromCreator defines a gRPC query method for fetching all denominations created by a specific admin/creator. | GET|/osmosis/tokenfactory/v1beta1/denoms_from_creator/{creator}|

 <!-- end services -->



<a name="cosmwasm/tokenfactory/v1beta1/tx.proto"></a>
<p align="right"><a href="#top">Top</a></p>

## cosmwasm/tokenfactory/v1beta1/tx.proto



<a name="cosmwasm.tokenfactory.v1beta1.MsgBurn"></a>

### MsgBurn
MsgBurn is the sdk.Msg type for allowing an admin account to burn
a token.  For now, we only support burning from the sender account.


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `sender` | [string](#string) |  |  |
| `amount` | [cosmos.base.v1beta1.Coin](#cosmos.base.v1beta1.Coin) |  |  |






<a name="cosmwasm.tokenfactory.v1beta1.MsgBurnResponse"></a>

### MsgBurnResponse







<a name="cosmwasm.tokenfactory.v1beta1.MsgChangeAdmin"></a>

### MsgChangeAdmin
MsgChangeAdmin is the sdk.Msg type for allowing an admin account to reassign
adminship of a denom to a new account


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `sender` | [string](#string) |  |  |
| `denom` | [string](#string) |  |  |
| `new_admin` | [string](#string) |  |  |






<a name="cosmwasm.tokenfactory.v1beta1.MsgChangeAdminResponse"></a>

### MsgChangeAdminResponse
MsgChangeAdminResponse defines the response structure for an executed
MsgChangeAdmin message.






<a name="cosmwasm.tokenfactory.v1beta1.MsgCreateDenom"></a>

### MsgCreateDenom
MsgCreateDenom defines the message structure for the CreateDenom gRPC service
method. It allows an account to create a new denom. It requires a sender
address and a sub denomination. The (sender_address, sub_denomination) tuple
must be unique and cannot be re-used.

The resulting denom created is defined as
<factory/{creatorAddress}/{subdenom}>. The resulting denom's admin is
originally set to be the creator, but this can be changed later. The token
denom does not indicate the current admin.


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `sender` | [string](#string) |  |  |
| `subdenom` | [string](#string) |  | subdenom can be up to 44 "alphanumeric" characters long. |






<a name="cosmwasm.tokenfactory.v1beta1.MsgCreateDenomResponse"></a>

### MsgCreateDenomResponse
MsgCreateDenomResponse is the return value of MsgCreateDenom
It returns the full string of the newly created denom


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `new_token_denom` | [string](#string) |  |  |






<a name="cosmwasm.tokenfactory.v1beta1.MsgMint"></a>

### MsgMint
MsgMint is the sdk.Msg type for allowing an admin account to mint
more of a token.  For now, we only support minting to the sender account


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `sender` | [string](#string) |  |  |
| `amount` | [cosmos.base.v1beta1.Coin](#cosmos.base.v1beta1.Coin) |  |  |






<a name="cosmwasm.tokenfactory.v1beta1.MsgMintResponse"></a>

### MsgMintResponse







<a name="cosmwasm.tokenfactory.v1beta1.MsgSetDenomMetadata"></a>

### MsgSetDenomMetadata
MsgSetDenomMetadata is the sdk.Msg type for allowing an admin account to set
the denom's bank metadata


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `sender` | [string](#string) |  |  |
| `metadata` | [cosmos.bank.v1beta1.Metadata](#cosmos.bank.v1beta1.Metadata) |  |  |






<a name="cosmwasm.tokenfactory.v1beta1.MsgSetDenomMetadataResponse"></a>

### MsgSetDenomMetadataResponse
MsgSetDenomMetadataResponse defines the response structure for an executed
MsgSetDenomMetadata message.





 <!-- end messages -->

 <!-- end enums -->

 <!-- end HasExtensions -->


<a name="cosmwasm.tokenfactory.v1beta1.Msg"></a>

### Msg
Msg defines the tokefactory module's gRPC message service.

| Method Name | Request Type | Response Type | Description | HTTP Verb | Endpoint |
| ----------- | ------------ | ------------- | ------------| ------- | -------- |
| `CreateDenom` | [MsgCreateDenom](#cosmwasm.tokenfactory.v1beta1.MsgCreateDenom) | [MsgCreateDenomResponse](#cosmwasm.tokenfactory.v1beta1.MsgCreateDenomResponse) |  | |
| `Mint` | [MsgMint](#cosmwasm.tokenfactory.v1beta1.MsgMint) | [MsgMintResponse](#cosmwasm.tokenfactory.v1beta1.MsgMintResponse) |  | |
| `Burn` | [MsgBurn](#cosmwasm.tokenfactory.v1beta1.MsgBurn) | [MsgBurnResponse](#cosmwasm.tokenfactory.v1beta1.MsgBurnResponse) |  | |
| `ChangeAdmin` | [MsgChangeAdmin](#cosmwasm.tokenfactory.v1beta1.MsgChangeAdmin) | [MsgChangeAdminResponse](#cosmwasm.tokenfactory.v1beta1.MsgChangeAdminResponse) |  | |
| `SetDenomMetadata` | [MsgSetDenomMetadata](#cosmwasm.tokenfactory.v1beta1.MsgSetDenomMetadata) | [MsgSetDenomMetadataResponse](#cosmwasm.tokenfactory.v1beta1.MsgSetDenomMetadataResponse) |  | |

 <!-- end services -->



<a name="cosmwasm/wasm/v1/tx.proto"></a>
<p align="right"><a href="#top">Top</a></p>

## cosmwasm/wasm/v1/tx.proto



<a name="cosmwasm.wasm.v1.MsgClearAdmin"></a>

### MsgClearAdmin
MsgClearAdmin removes any admin stored for a smart contract


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `sender` | [string](#string) |  | Sender is the actor that signed the messages |
| `contract` | [string](#string) |  | Contract is the address of the smart contract |






<a name="cosmwasm.wasm.v1.MsgClearAdminResponse"></a>

### MsgClearAdminResponse
MsgClearAdminResponse returns empty data






<a name="cosmwasm.wasm.v1.MsgExecuteContract"></a>

### MsgExecuteContract
MsgExecuteContract submits the given message data to a smart contract


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `sender` | [string](#string) |  | Sender is the that actor that signed the messages |
| `contract` | [string](#string) |  | Contract is the address of the smart contract |
| `msg` | [bytes](#bytes) |  | Msg json encoded message to be passed to the contract |
| `funds` | [cosmos.base.v1beta1.Coin](#cosmos.base.v1beta1.Coin) | repeated | Funds coins that are transferred to the contract on execution |






<a name="cosmwasm.wasm.v1.MsgExecuteContractResponse"></a>

### MsgExecuteContractResponse
MsgExecuteContractResponse returns execution result data.


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `data` | [bytes](#bytes) |  | Data contains bytes to returned from the contract |






<a name="cosmwasm.wasm.v1.MsgInstantiateContract"></a>

### MsgInstantiateContract
MsgInstantiateContract create a new smart contract instance for the given
code id.


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `sender` | [string](#string) |  | Sender is the that actor that signed the messages |
| `admin` | [string](#string) |  | Admin is an optional address that can execute migrations |
| `code_id` | [uint64](#uint64) |  | CodeID is the reference to the stored WASM code |
| `label` | [string](#string) |  | Label is optional metadata to be stored with a contract instance. |
| `msg` | [bytes](#bytes) |  | Msg json encoded message to be passed to the contract on instantiation |
| `funds` | [cosmos.base.v1beta1.Coin](#cosmos.base.v1beta1.Coin) | repeated | Funds coins that are transferred to the contract on instantiation |






<a name="cosmwasm.wasm.v1.MsgInstantiateContract2"></a>

### MsgInstantiateContract2
MsgInstantiateContract2 create a new smart contract instance for the given
code id with a predicable address.


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `sender` | [string](#string) |  | Sender is the that actor that signed the messages |
| `admin` | [string](#string) |  | Admin is an optional address that can execute migrations |
| `code_id` | [uint64](#uint64) |  | CodeID is the reference to the stored WASM code |
| `label` | [string](#string) |  | Label is optional metadata to be stored with a contract instance. |
| `msg` | [bytes](#bytes) |  | Msg json encoded message to be passed to the contract on instantiation |
| `funds` | [cosmos.base.v1beta1.Coin](#cosmos.base.v1beta1.Coin) | repeated | Funds coins that are transferred to the contract on instantiation |
| `salt` | [bytes](#bytes) |  | Salt is an arbitrary value provided by the sender. Size can be 1 to 64. |
| `fix_msg` | [bool](#bool) |  | FixMsg include the msg value into the hash for the predictable address. Default is false |






<a name="cosmwasm.wasm.v1.MsgInstantiateContract2Response"></a>

### MsgInstantiateContract2Response
MsgInstantiateContract2Response return instantiation result data


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `address` | [string](#string) |  | Address is the bech32 address of the new contract instance. |
| `data` | [bytes](#bytes) |  | Data contains bytes to returned from the contract |






<a name="cosmwasm.wasm.v1.MsgInstantiateContractResponse"></a>

### MsgInstantiateContractResponse
MsgInstantiateContractResponse return instantiation result data


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `address` | [string](#string) |  | Address is the bech32 address of the new contract instance. |
| `data` | [bytes](#bytes) |  | Data contains bytes to returned from the contract |






<a name="cosmwasm.wasm.v1.MsgMigrateContract"></a>

### MsgMigrateContract
MsgMigrateContract runs a code upgrade/ downgrade for a smart contract


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `sender` | [string](#string) |  | Sender is the that actor that signed the messages |
| `contract` | [string](#string) |  | Contract is the address of the smart contract |
| `code_id` | [uint64](#uint64) |  | CodeID references the new WASM code |
| `msg` | [bytes](#bytes) |  | Msg json encoded message to be passed to the contract on migration |






<a name="cosmwasm.wasm.v1.MsgMigrateContractResponse"></a>

### MsgMigrateContractResponse
MsgMigrateContractResponse returns contract migration result data.


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `data` | [bytes](#bytes) |  | Data contains same raw bytes returned as data from the wasm contract. (May be empty) |






<a name="cosmwasm.wasm.v1.MsgStoreCode"></a>

### MsgStoreCode
MsgStoreCode submit Wasm code to the system


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `sender` | [string](#string) |  | Sender is the actor that signed the messages |
| `wasm_byte_code` | [bytes](#bytes) |  | WASMByteCode can be raw or gzip compressed |
| `instantiate_permission` | [AccessConfig](#cosmwasm.wasm.v1.AccessConfig) |  | InstantiatePermission access control to apply on contract creation, optional |






<a name="cosmwasm.wasm.v1.MsgStoreCodeResponse"></a>

### MsgStoreCodeResponse
MsgStoreCodeResponse returns store result data.


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `code_id` | [uint64](#uint64) |  | CodeID is the reference to the stored WASM code |
| `checksum` | [bytes](#bytes) |  | Checksum is the sha256 hash of the stored code |






<a name="cosmwasm.wasm.v1.MsgUpdateAdmin"></a>

### MsgUpdateAdmin
MsgUpdateAdmin sets a new admin for a smart contract


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `sender` | [string](#string) |  | Sender is the that actor that signed the messages |
| `new_admin` | [string](#string) |  | NewAdmin address to be set |
| `contract` | [string](#string) |  | Contract is the address of the smart contract |






<a name="cosmwasm.wasm.v1.MsgUpdateAdminResponse"></a>

### MsgUpdateAdminResponse
MsgUpdateAdminResponse returns empty data






<a name="cosmwasm.wasm.v1.MsgUpdateInstantiateConfig"></a>

### MsgUpdateInstantiateConfig
MsgUpdateInstantiateConfig updates instantiate config for a smart contract


| Field | Type | Label | Description |
| ----- | ---- | ----- | ----------- |
| `sender` | [string](#string) |  | Sender is the that actor that signed the messages |
| `code_id` | [uint64](#uint64) |  | CodeID references the stored WASM code |
| `new_instantiate_permission` | [AccessConfig](#cosmwasm.wasm.v1.AccessConfig) |  | NewInstantiatePermission is the new access control |






<a name="cosmwasm.wasm.v1.MsgUpdateInstantiateConfigResponse"></a>

### MsgUpdateInstantiateConfigResponse
MsgUpdateInstantiateConfigResponse returns empty data





 <!-- end messages -->

 <!-- end enums -->

 <!-- end HasExtensions -->


<a name="cosmwasm.wasm.v1.Msg"></a>

### Msg
Msg defines the wasm Msg service.

| Method Name | Request Type | Response Type | Description | HTTP Verb | Endpoint |
| ----------- | ------------ | ------------- | ------------| ------- | -------- |
| `StoreCode` | [MsgStoreCode](#cosmwasm.wasm.v1.MsgStoreCode) | [MsgStoreCodeResponse](#cosmwasm.wasm.v1.MsgStoreCodeResponse) | StoreCode to submit Wasm code to the system | |
| `InstantiateContract` | [MsgInstantiateContract](#cosmwasm.wasm.v1.MsgInstantiateContract) | [MsgInstantiateContractResponse](#cosmwasm.wasm.v1.MsgInstantiateContractResponse) | InstantiateContract creates a new smart contract instance for the given code id. | |
| `InstantiateContract2` | [MsgInstantiateContract2](#cosmwasm.wasm.v1.MsgInstantiateContract2) | [MsgInstantiateContract2Response](#cosmwasm.wasm.v1.MsgInstantiateContract2Response) | InstantiateContract2 creates a new smart contract instance for the given code id with a predictable address | |
| `ExecuteContract` | [MsgExecuteContract](#cosmwasm.wasm.v1.MsgExecuteContract) | [MsgExecuteContractResponse](#cosmwasm.wasm.v1.MsgExecuteContractResponse) | Execute submits the given message data to a smart contract | |
| `MigrateContract` | [MsgMigrateContract](#cosmwasm.wasm.v1.MsgMigrateContract) | [MsgMigrateContractResponse](#cosmwasm.wasm.v1.MsgMigrateContractResponse) | Migrate runs a code upgrade/ downgrade for a smart contract | |
| `UpdateAdmin` | [MsgUpdateAdmin](#cosmwasm.wasm.v1.MsgUpdateAdmin) | [MsgUpdateAdminResponse](#cosmwasm.wasm.v1.MsgUpdateAdminResponse) | UpdateAdmin sets a new admin for a smart contract | |
| `ClearAdmin` | [MsgClearAdmin](#cosmwasm.wasm.v1.MsgClearAdmin) | [MsgClearAdminResponse](#cosmwasm.wasm.v1.MsgClearAdminResponse) | ClearAdmin removes any admin stored for a smart contract | |
| `UpdateInstantiateConfig` | [MsgUpdateInstantiateConfig](#cosmwasm.wasm.v1.MsgUpdateInstantiateConfig) | [MsgUpdateInstantiateConfigResponse](#cosmwasm.wasm.v1.MsgUpdateInstantiateConfigResponse) | UpdateInstantiateConfig updates instantiate config for a smart contract | |

 <!-- end services -->



## Scalar Value Types

| .proto Type | Notes | C++ | Java | Python | Go | C# | PHP | Ruby |
| ----------- | ----- | --- | ---- | ------ | -- | -- | --- | ---- |
| <a name="double" /> double |  | double | double | float | float64 | double | float | Float |
| <a name="float" /> float |  | float | float | float | float32 | float | float | Float |
| <a name="int32" /> int32 | Uses variable-length encoding. Inefficient for encoding negative numbers – if your field is likely to have negative values, use sint32 instead. | int32 | int | int | int32 | int | integer | Bignum or Fixnum (as required) |
| <a name="int64" /> int64 | Uses variable-length encoding. Inefficient for encoding negative numbers – if your field is likely to have negative values, use sint64 instead. | int64 | long | int/long | int64 | long | integer/string | Bignum |
| <a name="uint32" /> uint32 | Uses variable-length encoding. | uint32 | int | int/long | uint32 | uint | integer | Bignum or Fixnum (as required) |
| <a name="uint64" /> uint64 | Uses variable-length encoding. | uint64 | long | int/long | uint64 | ulong | integer/string | Bignum or Fixnum (as required) |
| <a name="sint32" /> sint32 | Uses variable-length encoding. Signed int value. These more efficiently encode negative numbers than regular int32s. | int32 | int | int | int32 | int | integer | Bignum or Fixnum (as required) |
| <a name="sint64" /> sint64 | Uses variable-length encoding. Signed int value. These more efficiently encode negative numbers than regular int64s. | int64 | long | int/long | int64 | long | integer/string | Bignum |
| <a name="fixed32" /> fixed32 | Always four bytes. More efficient than uint32 if values are often greater than 2^28. | uint32 | int | int | uint32 | uint | integer | Bignum or Fixnum (as required) |
| <a name="fixed64" /> fixed64 | Always eight bytes. More efficient than uint64 if values are often greater than 2^56. | uint64 | long | int/long | uint64 | ulong | integer/string | Bignum |
| <a name="sfixed32" /> sfixed32 | Always four bytes. | int32 | int | int | int32 | int | integer | Bignum or Fixnum (as required) |
| <a name="sfixed64" /> sfixed64 | Always eight bytes. | int64 | long | int/long | int64 | long | integer/string | Bignum |
| <a name="bool" /> bool |  | bool | boolean | boolean | bool | bool | boolean | TrueClass/FalseClass |
| <a name="string" /> string | A string must always contain UTF-8 encoded or 7-bit ASCII text. | string | String | str/unicode | string | string | string | String (UTF-8) |
| <a name="bytes" /> bytes | May contain any arbitrary sequence of bytes. | string | ByteString | str | []byte | ByteString | string | String (ASCII-8BIT) |

