//! Shim onto the ict-rs examples.
//!
//! ```sh
//! cargo run --manifest-path tests/interchaintest/Cargo.toml --bin ict -- ibc_hooks
//! ```
//!
//! The example source stays in `crates/ict-rs`. This binary only selects the
//! cargo feature set and forwards the environment, including `TERP_IMAGE_REPO`
//! and `TERP_IMAGE_VERSION`.

use std::path::PathBuf;
use std::process::Command;

fn package(example: &str) -> &'static str {
    match example {
        "svg_mint_cw_orch_runtime" => "ict-rs-cw-orch",
        _ => "ict-rs",
    }
}

fn features(example: &str) -> &'static str {
    match example {
        "epoch_claim" => "epoch-claim",
        "hashmerchant" | "hashmerchant_ve_oracle" => "docker,ethereum,hashmerchant",
        "nostr_calendar" => "docker,nostr",
        "trustless_builder" => "docker,ethereum",
        "svg_mint_cw_orch_runtime" => "docker",
        _ => "docker,terp,testing",
    }
}

fn main() {
    let mut args = std::env::args().skip(1);
    let Some(example) = args.next() else {
        eprintln!("usage: ict <example> [extra cargo args]");
        std::process::exit(2);
    };
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../crates/ict-rs/Cargo.toml");
    let mut cmd = Command::new("cargo");
    cmd.arg("run")
        .arg("--offline")
        .arg("--manifest-path")
        .arg(&manifest)
        .arg("-p")
        .arg(package(&example))
        .arg("--example")
        .arg(&example)
        .arg("--features")
        .arg(features(&example));
    for extra in args {
        cmd.arg(extra);
    }
    cmd.envs(std::env::vars());
    let status = cmd.status().unwrap_or_else(|e| {
        eprintln!("cargo run -p ict-rs --example {example}: {e}");
        std::process::exit(1);
    });
    std::process::exit(status.code().unwrap_or(1));
}
