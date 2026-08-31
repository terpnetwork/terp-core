//! Port of Go `TestTerpTokenFactory`.

use ict_rs::modules::tokenfactory::{TokenfactoryMsgExt, TokenfactoryQueryExt};
use ict_rs::prelude::*;
use ict_rs::testing::{setup_chain, TestEnv};

fn cfg() -> ChainConfig {
    let mut c = TestEnv::terp_config();
    c.gas_prices = "0uterp".to_string();
    c.gas_adjustment = 2.0;
    c
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut tc = setup_chain("e2e_tokenfactory", cfg()).await?;
    let tx = tc.chain.tokenfactory_create_denom("default", "ictestdenom").await?;
    assert!(tx.height > 0, "create-denom");
    let q = tc
        .chain
        .tokenfactory_denom_authority_metadata(
            "factory/terp1user000000000000000000000000000000/ictestdenom",
        )
        .await?;
    assert!(q.is_object());
    tc.cleanup().await?;
    println!("tokenfactory ok");
    Ok(())
}
