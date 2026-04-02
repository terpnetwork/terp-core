use cosmwasm_schema::{cw_serde, QueryResponses};

#[cw_serde]
pub struct InstantiateMsg {}

#[cw_serde]
pub enum ExecuteMsg {
    /// Check if claimed_root matches the last confirmed root for (chain_uid, algo).
    VerifyInclusion {
        chain_uid: String,
        algo: String,
        claimed_root: String, // hex-encoded
    },
}

#[cw_serde]
#[derive(QueryResponses)]
pub enum QueryMsg {
    /// Return the stored root for a (chain_uid, algo) pair.
    #[returns(RootResponse)]
    GetRoot { chain_uid: String, algo: String },
}

#[cw_serde]
pub struct RootResponse {
    pub chain_uid: String,
    pub algo: String,
    pub root: String, // hex-encoded
    pub height: u64,
    pub attestation_count: u32,
    pub block_time: i64,
}

/// Sudo message dispatched by the x/hashmerchant module.
#[cw_serde]
pub struct HashMerchantSudoMsg {
    pub hash_merchant: HashMerchantSudoPayload,
}

#[cw_serde]
pub struct HashMerchantSudoPayload {
    pub chain_uid: String,
    pub algo: String,
    pub height: u64,
    pub root: String,               // base64 from JSON (binary field)
    pub attestation_count: u32,
    pub block_time: i64,
}
