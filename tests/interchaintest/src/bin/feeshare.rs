//! Port of Go `TestTerpFeeShare`.

use ict_rs::cosmwasm::CosmWasmExt;
use ict_rs::modules::feeshare::FeeshareMsgExt;
use ict_rs::prelude::*;
use ict_rs::testing::{setup_chain, TestEnv};

fn cfg() -> ChainConfig {
    let mut c = TestEnv::terp_config();
    c.gas_prices = "0uterp".to_string();
    c
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut tc = setup_chain("e2e_feeshare", cfg()).await?;
    let tx = tc
        .chain
        .feeshare_register_fee_share(
            "default",
            "terp1mockcontract1",
            "terp1mockdeployer",
            "terp1mockwithdrawer",
        )
        .await?;
    assert!(tx.height > 0, "register-fee-share");
    let exec = tc
        .chain
        .execute_contract("default", "terp1mockcontract1", r#"{"increment":{}}"#, None)
        .await?;
    assert!(exec.height > 0);
    tc.cleanup().await?;
    println!("feeshare ok");
    Ok(())
}
