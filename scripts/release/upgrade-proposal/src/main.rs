//! Submit a Cosmos SDK v1 software-upgrade proposal via cw-orch-daemon.
//!
//! Mnemonic is never committed. Put it in `scripts/release/.env` as `MAIN_MNEMONIC`.
//! Default is dry-run; pass `--broadcast` to sign and send.

use anyhow::{bail, Context, Result};
use clap::Parser;
use cosmos_sdk_proto::cosmos::base::v1beta1::Coin as ProtoCoin;
use cosmos_sdk_proto::cosmos::gov::v1::MsgSubmitProposal;
use cosmos_sdk_proto::cosmos::upgrade::v1beta1::{MsgSoftwareUpgrade, Plan};
use cosmos_sdk_proto::traits::Message;
use cw_orch_core::environment::{ChainInfoOwned, ChainKind, NetworkInfoOwned, TxHandler};
use cw_orch_daemon::DaemonBuilder;
use cw_orch_traits::Stargate;
use prost_types::Any;
use serde::Deserialize;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Parser, Debug)]
#[command(name = "terp-upgrade-proposal", about = "Submit terp-core v6 software-upgrade via cw-orch")]
struct Args {
    /// Path to draft proposal JSON (terpd tx gov submit-proposal format).
    #[arg(long, default_value = "networks/upgrades/v6/draft_proposal.json")]
    proposal: PathBuf,

    /// dotenv file with MAIN_MNEMONIC / GRPC_URL. Default: scripts/release/.env
    #[arg(long, env = "UPGRADE_ENV_FILE")]
    env_file: Option<PathBuf>,

    /// Sign and broadcast. Without this flag, only prints the constructed tx payload.
    #[arg(long)]
    broadcast: bool,

    /// Override chain id (else CHAIN_ID env, else morocco-1).
    #[arg(long, env = "CHAIN_ID")]
    chain_id: Option<String>,

    /// gRPC endpoint (required for --broadcast).
    #[arg(long, env = "GRPC_URL")]
    grpc_url: Option<String>,
}

#[derive(Debug, Deserialize)]
struct DraftProposal {
    messages: Vec<serde_json::Value>,
    #[serde(default)]
    metadata: String,
    deposit: String,
    title: String,
    summary: String,
    #[serde(default)]
    expedited: bool,
}

fn repo_root() -> PathBuf {
    // scripts/release/upgrade-proposal -> repo root
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|p| p.parent())
        .and_then(|p| p.parent())
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."))
}

fn load_env(path: &Path) -> Result<()> {
    if path.exists() {
        dotenvy::from_path(path).with_context(|| format!("loading {}", path.display()))?;
        log::info!("loaded env from {}", path.display());
    } else {
        log::warn!(
            "no env file at {} — copy scripts/release/.env.example to scripts/release/.env",
            path.display()
        );
        let _ = dotenvy::dotenv();
    }
    Ok(())
}

fn parse_coin(s: &str) -> Result<ProtoCoin> {
    let i = s
        .find(|c: char| c.is_ascii_alphabetic())
        .context("deposit must look like 10000000000uterp")?;
    Ok(ProtoCoin {
        amount: s[..i].to_string(),
        denom: s[i..].to_string(),
    })
}

fn chain_kind(s: &str) -> ChainKind {
    match s.to_ascii_lowercase().as_str() {
        "testnet" => ChainKind::Testnet,
        "local" => ChainKind::Local,
        _ => ChainKind::Mainnet,
    }
}

fn chain_info(args: &Args) -> Result<ChainInfoOwned> {
    let chain_id = args
        .chain_id
        .clone()
        .or_else(|| std::env::var("CHAIN_ID").ok())
        .unwrap_or_else(|| "morocco-1".into());
    let grpc = args
        .grpc_url
        .clone()
        .or_else(|| std::env::var("GRPC_URL").ok())
        .unwrap_or_else(|| "http://127.0.0.1:9090".into());
    let gas_denom = std::env::var("GAS_DENOM").unwrap_or_else(|_| "uterp".into());
    let gas_price: f64 = std::env::var("GAS_PRICE")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0.025);
    let prefix = std::env::var("ADDRESS_PREFIX").unwrap_or_else(|_| "terp".into());
    let kind = chain_kind(&std::env::var("CHAIN_KIND").unwrap_or_else(|_| "mainnet".into()));
    Ok(ChainInfoOwned {
        chain_id,
        gas_denom,
        gas_price,
        grpc_urls: vec![grpc],
        lcd_url: std::env::var("LCD_URL").ok(),
        fcd_url: None,
        network_info: NetworkInfoOwned {
            chain_name: "terp".into(),
            pub_address_prefix: prefix,
            coin_type: 118,
        },
        kind,
    })
}

fn inner_msgs(draft: &DraftProposal) -> Result<Vec<cosmos_sdk_proto::Any>> {
    let mut out = Vec::new();
    for msg in &draft.messages {
        let type_url = msg
            .get("@type")
            .and_then(|v| v.as_str())
            .context("proposal message missing @type")?;
        match type_url {
            "/cosmos.upgrade.v1beta1.MsgSoftwareUpgrade" => {
                let authority = msg
                    .get("authority")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let plan = msg.get("plan").context("MsgSoftwareUpgrade missing plan")?;
                let name = plan
                    .get("name")
                    .and_then(|v| v.as_str())
                    .unwrap_or("v6")
                    .to_string();
                let height: i64 = plan
                    .get("height")
                    .and_then(|v| {
                        v.as_i64()
                            .or_else(|| v.as_str().and_then(|s| s.parse().ok()))
                    })
                    .context("plan.height")?;
                let info = plan
                    .get("info")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                #[allow(deprecated)]
                let upgrade = MsgSoftwareUpgrade {
                    authority,
                    plan: Some(Plan {
                        name,
                        time: None,
                        height,
                        info,
                        upgraded_client_state: None,
                    }),
                };
                out.push(cosmos_sdk_proto::Any {
                    type_url: type_url.to_string(),
                    value: upgrade.encode_to_vec(),
                });
            }
            other => bail!("unsupported proposal message type {other}"),
        }
    }
    Ok(out)
}

fn build_submit(draft: &DraftProposal, proposer: &str) -> Result<MsgSubmitProposal> {
    Ok(MsgSubmitProposal {
        messages: inner_msgs(draft)?,
        initial_deposit: vec![parse_coin(&draft.deposit)?],
        proposer: proposer.to_string(),
        metadata: draft.metadata.clone(),
        title: draft.title.clone(),
        summary: draft.summary.clone(),
        expedited: draft.expedited,
    })
}

fn to_prost_any(msg: &MsgSubmitProposal) -> Any {
    Any {
        type_url: "/cosmos.gov.v1.MsgSubmitProposal".to_string(),
        value: msg.encode_to_vec(),
    }
}

fn main() -> Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();
    let args = Args::parse();
    let root = repo_root();
    let env_path = args.env_file.clone().unwrap_or_else(|| {
        std::env::var("UPGRADE_ENV_FILE")
            .map(PathBuf::from)
            .unwrap_or_else(|_| root.join("scripts/release/.env"))
    });
    load_env(&env_path)?;

    let proposal_path = if args.proposal.is_absolute() {
        args.proposal.clone()
    } else {
        root.join(&args.proposal)
    };
    let draft: DraftProposal = serde_json::from_str(
        &fs::read_to_string(&proposal_path)
            .with_context(|| format!("read {}", proposal_path.display()))?,
    )?;

    if draft.expedited {
        log::warn!("draft_proposal.json has expedited=true; v6 pack is supposed to be normal gov");
    }

    let chain = chain_info(&args)?;
    let mnemonic = std::env::var("MAIN_MNEMONIC")
        .or_else(|_| std::env::var("TEST_MNEMONIC"))
        .or_else(|_| std::env::var("LOCAL_MNEMONIC"))
        .context("set MAIN_MNEMONIC in scripts/release/.env")?;

    println!("chain_id: {}", chain.chain_id);
    println!("grpc: {}", chain.grpc_urls.first().unwrap_or(&String::new()));
    println!("title: {}", draft.title);
    println!("deposit: {}", draft.deposit);
    println!("expedited: {}", draft.expedited);
    println!(
        "plan.height: {}",
        draft.messages[0]
            .get("plan")
            .and_then(|p| p.get("height"))
            .unwrap_or(&serde_json::Value::Null)
    );
    println!(
        "mnemonic: loaded from {} ({} words)",
        env_path.display(),
        mnemonic.split_whitespace().count()
    );

    if !args.broadcast {
        let submit = build_submit(&draft, "PROPOSER_ON_BROADCAST")?;
        let any = to_prost_any(&submit);
        println!(
            "MsgSubmitProposal bytes: {} (type {})",
            any.value.len(),
            any.type_url
        );
        println!("dry-run only. pass --broadcast to connect, sign, and submit on-chain.");
        return Ok(());
    }

    let mut builder = DaemonBuilder::new(chain.clone());
    builder
        .mnemonic(&mnemonic)
        .load_network(false)
        .is_test(true);
    let daemon = builder
        .build()
        .context("build cw-orch daemon (check GRPC_URL / mnemonic)")?;

    let proposer = daemon.sender_addr().to_string();
    println!("proposer: {proposer}");
    let submit = build_submit(&draft, &proposer)?;
    let any = to_prost_any(&submit);

    let resp = daemon
        .commit_any(vec![any], Some("terp v6 software upgrade proposal"))
        .context("broadcast MsgSubmitProposal")?;
    println!("txhash: {}", resp.txhash);
    Ok(())
}
