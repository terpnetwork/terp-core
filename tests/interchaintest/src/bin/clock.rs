//! Port of Go `TestTerpClock`.

use ict_rs::modules::clock::ClockQueryExt;
use ict_rs::prelude::*;
use ict_rs::testing::{setup_chain, TestEnv};

fn cfg() -> ChainConfig {
    let mut c = TestEnv::terp_config();
    c.gas_prices = "0uterp".to_string();
    c
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut tc = setup_chain("e2e_clock", cfg()).await?;
    let params = tc.chain.clock_params().await?;
    assert!(params.is_object(), "clock params");
    let contracts = tc.chain.clock_clock_contracts().await?;
    assert!(contracts.is_object() || contracts.is_array());
    tc.cleanup().await?;
    println!("clock ok {params}");
    Ok(())
}
