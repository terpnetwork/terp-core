// generate circuit keys
use base64::Engine as _;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::io::Write;
use std::path::Path;
/// BoxError
pub type BoxError = Box<dyn std::error::Error + Send + Sync>;

use base64::{engine::general_purpose::STANDARD, Engine as _};

/// # logic to create & verify circuit and proofs for testing in zk-wasmvm integrations.
/// - generates default testing circuits [VerifyingKey] and [ProvingKey]
/// used as a part of verifiable deployments of headstashes
/// ```sh
///  cargo run --bin create_test_circuit_data
/// ```
// Generate test circuit keys for all example circuits

fn main() -> Result<(), BoxError> {
    let suite = zk_cosmwasm::TestPressSuite::new();
    let path = Path::new("../../interchaintest/circuits");
    // Write to JSON file
    let json_file = "../../interchaintest/circuits/no_rick_proof.json";

    // Words we want in the output JSON
    let words = vec!["rick", "morty", "summer"];

    // Generate proofs (only rick is real for now)
    let proofs = zk_cosmwasm::TestPressLaunchpadInstance::gen_test_circuit_keys(
        &suite,
        path,
        None,
        vec![("randy", words[0])],
    )?;

    eprintln!("\n🎉 All circuit keys generated successfully!");

    // Map proofs by word for easy lookup
    let mut proof_by_word: BTreeMap<String, Vec<u8>> = BTreeMap::new();
    proof_by_word.insert("rick".to_string(), proofs[0].bytes().clone());

    // Build final JSON object
    let mut output = serde_json::Map::new();

    for word in words {

        let proof_b64 = proof_by_word
            .get(word)
            .map(|bytes| STANDARD.encode(bytes))
            .unwrap_or_else(|| format!("ADD_{}_PROOF_HERE", word.to_uppercase()));

        // Instance scalar:
        // Always encode exactly ONE field element (32 bytes)
        // For now we use zero, but this is explicit and valid.
        let scalar_bytes = [0u8; 32];
        let scalar_b64 = STANDARD.encode(scalar_bytes);

        output.insert(
            word.to_string(),
            json!({
                "proof": proof_b64,
                "scalar": scalar_b64
            }),
        );
    }
    let json_output = serde_json::to_string_pretty(&Value::Object(output))?;
    let mut file = std::fs::File::create(json_file)?;
    file.write_all(json_output.as_bytes())?;

    eprintln!("Proofs written to {}", json_file);

    Ok(())
}
