pub mod msg;

use cosmwasm_std::{
    entry_point, to_json_binary, Binary, Deps, DepsMut, Env, MessageInfo,
    Response, StdError, StdResult,
};
use msg::*;

// Storage key: "root:{chain_uid}:{algo}" → JSON-encoded RootResponse
fn root_key(chain_uid: &str, algo: &str) -> String {
    format!("root:{}:{}", chain_uid, algo)
}

#[entry_point]
pub fn instantiate(
    _deps: DepsMut,
    _env: Env,
    _info: MessageInfo,
    _msg: InstantiateMsg,
) -> StdResult<Response> {
    Ok(Response::new().add_attribute("action", "instantiate"))
}

#[entry_point]
pub fn execute(
    deps: DepsMut,
    _env: Env,
    _info: MessageInfo,
    msg: ExecuteMsg,
) -> StdResult<Response> {
    match msg {
        ExecuteMsg::VerifyInclusion {
            chain_uid,
            algo,
            claimed_root,
        } => execute_verify_inclusion(deps.as_ref(), chain_uid, algo, claimed_root),
    }
}

fn execute_verify_inclusion(
    deps: Deps,
    chain_uid: String,
    algo: String,
    claimed_root: String,
) -> StdResult<Response> {
    let key = root_key(&chain_uid, &algo);
    let stored = deps.storage.get(key.as_bytes());

    match stored {
        None => Err(StdError::generic_err(format!(
            "no confirmed root for chain_uid={} algo={}",
            chain_uid, algo
        ))),
        Some(data) => {
            let root_resp: RootResponse = cosmwasm_std::from_json(&data)?;
            if root_resp.root == claimed_root {
                Ok(Response::new()
                    .add_attribute("action", "verify_inclusion")
                    .add_attribute("result", "valid")
                    .add_attribute("chain_uid", chain_uid)
                    .add_attribute("algo", algo))
            } else {
                Err(StdError::generic_err(format!(
                    "root mismatch: stored={} claimed={}",
                    root_resp.root, claimed_root
                )))
            }
        }
    }
}

#[entry_point]
pub fn sudo(deps: DepsMut, _env: Env, msg: HashMerchantSudoMsg) -> StdResult<Response> {
    let payload = msg.hash_merchant;

    // The module sends root as base64 (Go []byte → JSON).
    // Decode base64 → raw bytes → hex string for storage/comparison.
    let root_hex = base64_to_hex(&payload.root);

    let key = root_key(&payload.chain_uid, &payload.algo);
    let root_resp = RootResponse {
        chain_uid: payload.chain_uid.clone(),
        algo: payload.algo.clone(),
        root: root_hex,
        height: payload.height,
        attestation_count: payload.attestation_count,
        block_time: payload.block_time,
    };
    let value = cosmwasm_std::to_json_vec(&root_resp)?;
    deps.storage.set(key.as_bytes(), &value);

    Ok(Response::new()
        .add_attribute("action", "sudo_hash_merchant")
        .add_attribute("chain_uid", payload.chain_uid)
        .add_attribute("algo", payload.algo))
}

#[entry_point]
pub fn query(deps: Deps, _env: Env, msg: QueryMsg) -> StdResult<Binary> {
    match msg {
        QueryMsg::GetRoot { chain_uid, algo } => {
            let key = root_key(&chain_uid, &algo);
            let data = deps
                .storage
                .get(key.as_bytes())
                .ok_or_else(|| StdError::generic_err("root not found"))?;
            let root_resp: RootResponse = cosmwasm_std::from_json(&data)?;
            to_json_binary(&root_resp)
        }
    }
}

/// Decode a base64-encoded string to hex. Falls back to passthrough on error.
fn base64_to_hex(input: &str) -> String {
    match cosmwasm_std::Binary::from_base64(input) {
        Ok(bytes) => bytes
            .iter()
            .map(|b| format!("{:02x}", b))
            .collect::<String>(),
        Err(_) => input.to_string(),
    }
}
