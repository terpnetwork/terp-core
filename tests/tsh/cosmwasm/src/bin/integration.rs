// #
//     - cw721-base
//     - terp-account-billboards
//     - cw721-svg
//     - cw-infuser

use clap::Parser;
use cw721_svg::interface::Cw721Svg;
use cw_infuser_scripts::suite::{CwSvgSuite, CwSvgSuiteDeployData};
use cw_infuser_scripts::MOROCCO_1;
use cw_infusion_minter::msg::InstantiateMsg;
use cw_orch::daemon::DaemonBuilder;
use cw_orch::prelude::*;
use cw_orch::tokio::runtime::Runtime;
use cw_svg::InstantiateMsg as SvgInitMsg;

#[derive(Parser, Debug)]
#[clap(author, version, about, long_about = None)]
struct Args {
    /// Network to deploy on: main, testnet, local
    #[clap(short, long, default_value = "main")]
    network: String,

    #[clap(short, long, default_value = "deploy_on")]
    method: String,
}

pub fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    dotenv::dotenv()?;
    env_logger::init();

    let chain = match args.network.as_str() {
        "main" => MOROCCO_1.to_owned(),
        "testnet" => MOROCCO_1.to_owned(),
        "local" => MOROCCO_1.to_owned(),
        _ => panic!("Invalid network"),
    };
    workflow(chain.into(), &args.method)?;

    if args.method == "e2e".to_owned() {
        // if e2e test, invoke script to test minting workflow of front end
        // # configure ui to local local network
        //     - test minting interfaces for each command
    }
    Ok(())
}

fn workflow(network: ChainInfoOwned, _method: &String) -> anyhow::Result<()> {
    let rt = Runtime::new()?;
    // 1.  spin up local network (omit if production run)
    spinup()?;
    let mut chain = DaemonBuilder::new(network.clone())
        .handle(rt.handle())
        .build()?;

    // // 2. upload & instantiate all wasm contracts (omit if already exists (requires state.json))
    let suite = CwSvgSuite::deploy_on(chain.clone(), None)?;

    Ok(())
}

use anyhow::{anyhow, Context, Result};
use std::process::Command;

fn spinup() -> Result<()> {
    // 1. Build the localterp image
    println!("Building localterp image...");
    run_docker_command(
        "docker buildx build --target localterp -t terpnetwork/terp-core:localterp --load .",
    )?;
    println!("Starting localterp container...");
    run_docker_command(
        "docker run --rm -it -p 26657:26657 -p 1317:1317 -p 8545:8545 terpnetwork/terp-core:localterp"
    )?;
    println!("Container started successfully.");
    Ok(())
}

// // 2. upload & instantiate all wasm contracts (omit if already exists (requires state.json))
// let deploy_msgs = Some(CwSvgSuiteDeployData {
//     svg: Some(SvgInitMsg {
//         name: todo!(),
//         symbol: todo!(),
//         svg_template: todo!(),
//         variables: todo!(),
//         total: todo!(),
//         seed: todo!(),
//         owner: todo!(),
//         mint_start_time: todo!(),
//         mint_end_time: todo!(),
//         price_tiers: todo!(),
//         payment_address: todo!(),
//         whitelist: todo!(),
//     }),
//     infuse: Some(InstantiateMsg {
//         contract_owner: todo!(),
//         owner_fee: todo!(),
//         min_creation_fee: todo!(),
//         min_infusion_fee: todo!(),
//         min_per_bundle: todo!(),
//         max_per_bundle: todo!(),
//         max_bundles: todo!(),
//         max_infusions: todo!(),
//         cw721_code_id: todo!(),
//         wavs_public_key: todo!(),
//     }),
//     admin: Some(chain.sender_addr()),
//     infuse_coins: vec![],
// });

fn run_docker_command(cmd: &str) -> Result<()> {
    let mut parts = shlex::Shlex::new(cmd);
    let program = parts.next().ok_or_else(|| anyhow!("Empty command"))?;

    let args: Vec<String> = parts.collect();

    let status = Command::new(&program)
        .args(&args)
        .status()
        .with_context(|| format!("Failed to execute: {}", cmd))?;

    if !status.success() {
        return Err(anyhow!(
            "Command failed: {} (exit code: {:?})",
            cmd,
            status.code()
        ));
    }

    Ok(())
}
