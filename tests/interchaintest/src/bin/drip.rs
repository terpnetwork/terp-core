//! Port of Go `TestTerpDrip`.

use ict_rs::modules::drip::DripQueryExt;
use ict_rs::prelude::*;
use ict_rs::testing::{setup_chain, TestEnv};

fn cfg() -> ChainConfig {
    let mut c = TestEnv::terp_config();
    c.gas_prices = "0uterp".to_string();
    c
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut tc = setup_chain("e2e_drip", cfg()).await?;
    let params = tc.chain.drip_params().await?;
    assert!(params.is_object(), "drip params");
    tc.cleanup().await?;
    println!("drip ok {params}");
    Ok(())
}
