//! Offline No-Rick testdata: CosmWasm-footer VK + host Halo2 proofs.
//! Native only — no wasm-bindgen, no Daemon, no mnemonic.

#[path = "../../../../../crates/headstash/test-press/src/circuits/no_rick.rs"]
mod no_rick;

use std::fs;
use std::path::{Path, PathBuf};

use base64::Engine as _;
use halo2_proofs::circuit::Value;
use pasta_curves::pallas;
use rand::rngs::OsRng;
use serde_json::{json, Value as Json};

use no_rick::{NoRickCircuit, NoRickInstance, Proof, ProvingKey, VerifyingKey};

struct Case {
    name: &'static str,
    private_word: &'static str,
    forbidden: &'static str,
    expect_ok: bool,
}

const CASES: &[Case] = &[
    Case {
        name: "randy_no_rick",
        private_word: "randy",
        forbidden: "rick",
        expect_ok: true,
    },
    Case {
        name: "morty_no_rick",
        private_word: "morty",
        forbidden: "rick",
        expect_ok: true,
    },
    Case {
        name: "ricky_contains",
        private_word: "ricky",
        forbidden: "rick",
        expect_ok: false,
    },
];

fn circuit_from_word(word: &str) -> NoRickCircuit<pallas::Base> {
    let mut bytes = word.as_bytes().to_vec();
    bytes.resize(20, 0);
    let priv_input = bytes
        .iter()
        .map(|&b| Value::known(pallas::Base::from(b as u64)))
        .collect();
    NoRickCircuit { priv_input }
}

fn default_outdirs() -> Vec<PathBuf> {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    vec![
        manifest.join("../../../../artifacts/testdata"),
    ]
}

fn encode_hex(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for &b in bytes {
        out.push(HEX[(b >> 4) as usize] as char);
        out.push(HEX[(b & 0x0f) as usize] as char);
    }
    out
}

fn decode_hex(s: &str) -> Result<Vec<u8>, Box<dyn std::error::Error + Send + Sync>> {
    if s.len() % 2 != 0 {
        return Err("odd hex length".into());
    }
    let mut out = Vec::with_capacity(s.len() / 2);
    let b = s.as_bytes();
    let mut i = 0;
    while i < b.len() {
        let hi = hex_val(b[i])?;
        let lo = hex_val(b[i + 1])?;
        out.push((hi << 4) | lo);
        i += 2;
    }
    Ok(out)
}

fn hex_val(c: u8) -> Result<u8, Box<dyn std::error::Error + Send + Sync>> {
    match c {
        b'0'..=b'9' => Ok(c - b'0'),
        b'a'..=b'f' => Ok(c - b'a' + 10),
        b'A'..=b'F' => Ok(c - b'A' + 10),
        _ => Err("invalid hex".into()),
    }
}

fn write_dir(dir: &Path, vk: &[u8], cases: &Json) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    fs::create_dir_all(dir)?;
    fs::write(dir.join("norick_vk.bin"), vk)?;
    if let Some(arr) = cases.get("cases").and_then(|c| c.as_array()) {
        for c in arr {
            let name = c.get("name").and_then(|v| v.as_str()).unwrap_or("case");
            if let Some(hx) = c.get("proof_hex").and_then(|v| v.as_str()) {
                if !hx.is_empty() {
                    let bytes = decode_hex(hx)?;
                    fs::write(dir.join(format!("norick_proof_{name}.bin")), bytes)?;
                }
            }
        }
    }
    fs::write(dir.join("norick_cases.json"), serde_json::to_vec_pretty(cases)?)?;
    eprintln!("wrote {}", dir.display());
    Ok(())
}

fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut outdirs: Vec<PathBuf> = std::env::args().skip(1).map(PathBuf::from).collect();
    if outdirs.is_empty() {
        if let Ok(one) = std::env::var("NORICK_TESTDATA") {
            outdirs.push(PathBuf::from(one));
        } else {
            outdirs = default_outdirs();
        }
    }

    let primary = outdirs[0].clone();
    fs::create_dir_all(&primary)?;
    let vk_path = primary.join("norick_vk.bin");
    eprintln!("keygen -> {}", vk_path.display());
    let pk = ProvingKey::build_and_write(vk_path.clone())?;
    let vk = VerifyingKey::from(&pk);
    let vk_bytes = fs::read(&vk_path)?;

    let mut case_json = Vec::new();
    for case in CASES {
        let circuit = circuit_from_word(case.private_word);
        let instance = NoRickInstance {
            word: case.forbidden.to_string(),
        };
        let created = Proof::create(&pk, &[circuit], &[instance.clone()], OsRng);
        let (proof_bytes, local_ok, note) = match created {
            Ok(proof) => {
                let bytes = proof.bytes();
                match proof.verify(&vk, &[instance]) {
                    Ok(()) => (bytes, true, "verify_ok".to_string()),
                    Err(e) => (bytes, false, format!("verify_err:{e:?}")),
                }
            }
            Err(e) => (Vec::new(), false, format!("prove_err:{e:?}")),
        };
        if case.expect_ok != local_ok {
            eprintln!(
                "WARN {}: expect_ok={} local_ok={} ({note})",
                case.name, case.expect_ok, local_ok
            );
        } else {
            eprintln!(
                "OK {}: local_ok={local_ok} proof_len={}",
                case.name,
                proof_bytes.len()
            );
        }
        let proof_b64 = base64::engine::general_purpose::STANDARD.encode(&proof_bytes);
        case_json.push(json!({
            "name": case.name,
            "private_word": case.private_word,
            "forbidden": case.forbidden,
            "expect_ok": case.expect_ok,
            "local_ok": local_ok,
            "note": note,
            "proof_file": format!("norick_proof_{}.bin", case.name),
            "proof_b64": proof_b64,
            "proof_hex": encode_hex(&proof_bytes),
            "execute": {
                "proove": {
                    "cid": 1,
                    "forbidden": case.forbidden,
                    "proof": proof_b64,
                }
            }
        }));
    }

    let catalog = json!({
        "circuit": "norick",
        "k": 10,
        "prover": 0,
        "curve": 0,
        "vk_file": "norick_vk.bin",
        "vk_len": vk_bytes.len(),
        "source": "tests/tsh/zk/norick-testdata (host halo2, no wasm-bindgen)",
        "cases": case_json,
    });

    for dir in &outdirs {
        write_dir(dir, &vk_bytes, &catalog)?;
    }

    let repo_art = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../../artifacts");
    if repo_art.is_dir() {
        fs::write(repo_art.join("norick_vk.bin"), &vk_bytes)?;
        eprintln!("wrote {}", repo_art.join("norick_vk.bin").display());
    }
    let hs_art = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../../crates/headstash/artifacts");
    if hs_art.is_dir() {
        fs::write(hs_art.join("norick_vk.bin"), &vk_bytes)?;
        eprintln!("wrote {}", hs_art.join("norick_vk.bin").display());
    }

    println!("{}", serde_json::to_string_pretty(&catalog)?);
    Ok(())
}
