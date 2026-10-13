# E2E catalog

Every row runs against the terp-core image in `TERP_IMAGE_REPO` and `TERP_IMAGE_VERSION`. ict-rs examples are started from `tests/interchaintest` with `cargo run --bin ict -- <example>`, which forwards to `crates/ict-rs`.

Curated rows are the ones `ict-ci` runs, plus the DAO reply gate and `tests/tsh/upgrade/v63.sh`. Everything else is experimental.

Unit-test coverage is not in this table. Use `cargo carpulin --tool tarpaulin` from `crates/cargo-chec`. Profiles of a binary use `cargo flambe`.

Open the filter page with `make e2e-page`. It serves `tests/e2e` at http://127.0.0.1:8765.

## Local

| lane | tree | name | env | note |
|---|---|---|---|---|
| curated | ict-rs | `basic_cosmos` | `TERP_IMAGE_REPO TERP_IMAGE_VERSION` | cargo run --offline --bin ict -- basic_cosmos |
| curated | ict-rs | `integration_test` | `TERP_IMAGE_REPO TERP_IMAGE_VERSION` | cargo run --offline --bin ict -- integration_test |
| curated | ict-rs | `ibc_v2_callbacks` | `TERP_IMAGE_REPO TERP_IMAGE_VERSION` | cargo run --offline --bin ict -- ibc_v2_callbacks |
| curated | ict-rs | `pfm` | `TERP_IMAGE_REPO TERP_IMAGE_VERSION` | cargo run --offline --bin ict -- pfm |
| curated | ict-rs | `circuit_deposit` | `TERP_IMAGE_REPO TERP_IMAGE_VERSION` | cargo run --offline --bin ict -- circuit_deposit |
| experimental | ict-rs | `ibc_v2` | `TERP_IMAGE_REPO TERP_IMAGE_VERSION` | cargo run --offline --bin ict -- ibc_v2 |
| experimental | ict-rs | `ibc_wasm_lc` | `TERP_IMAGE_REPO TERP_IMAGE_VERSION` | cargo run --offline --bin ict -- ibc_wasm_lc |
| experimental | ict-rs | `marketplace_inventory_offline` | `TERP_IMAGE_REPO TERP_IMAGE_VERSION` | cargo run --offline --bin ict -- marketplace_inventory_offline |
| experimental | ict-rs | `loyalty_rewards_zkjwt` | `TERP_IMAGE_REPO TERP_IMAGE_VERSION` | cargo run --offline --bin ict -- loyalty_rewards_zkjwt |
| curated | ict-rs | `ibc_transfer` | `TERP_IMAGE_REPO TERP_IMAGE_VERSION` | cargo run --offline --bin ict -- ibc_transfer |
| curated | ict-rs | `polytone` | `TERP_IMAGE_REPO TERP_IMAGE_VERSION` | cargo run --offline --bin ict -- polytone |
| curated | ict-rs | `state_sync` | `TERP_IMAGE_REPO TERP_IMAGE_VERSION` | cargo run --offline --bin ict -- state_sync |
| experimental | ict-rs | `ibc_callbacks` | `TERP_IMAGE_REPO TERP_IMAGE_VERSION` | cargo run --offline --bin ict -- ibc_callbacks |
| experimental | ict-rs | `no_rick` | `TERP_IMAGE_REPO TERP_IMAGE_VERSION` | cargo run --offline --bin ict -- no_rick |
| experimental | ict-rs | `suite_wasm_smoke` | `TERP_IMAGE_REPO TERP_IMAGE_VERSION` | shim: cargo run -p ict-rs --example suite_wasm_smoke |
| experimental | ict-rs | `bulk_memory_gas` | `TERP_IMAGE_REPO TERP_IMAGE_VERSION ICT_BULK_WASM` | cargo run --offline --bin ict -- bulk_memory_gas |
| experimental | ict-rs | `headstash` | `TERP_IMAGE_REPO TERP_IMAGE_VERSION` | cargo run --offline --bin ict -- headstash |
| experimental | ict-rs | `hashmerchant` | `TERP_IMAGE_REPO TERP_IMAGE_VERSION` | cargo run --offline --bin ict -- hashmerchant |
| experimental | ict-rs | `epoch_claim` | `TERP_IMAGE_REPO TERP_IMAGE_VERSION` | cargo run --offline --bin ict -- epoch_claim |
| experimental | ict-rs | `snapshot` | `TERP_IMAGE_REPO TERP_IMAGE_VERSION` | cargo run --offline --bin ict -- snapshot |
| experimental | ict-rs | `cosmos_upgrade` | `TERP_IMAGE_REPO TERP_IMAGE_VERSION` | pre-v6 upgrade example; image still comes from the env |
| curated | terp-rs | `dao_modules_initialize_on_terp` | `ICT_DAO_ACTIONS=1 TERP_IMAGE_REPO TERP_IMAGE_VERSION` | cargo test -p dao-foundation-suite --test dao_actions_chain --offline -- --ignored --nocapture |
| curated | terp-rs | `reply_vs_instantiate2_gas` | `ICT_DAO_GAS=1 TERP_IMAGE_REPO TERP_IMAGE_VERSION` | cargo test -p dao-foundation-suite --test dao_reply_gas --offline -- --ignored --nocapture |
| experimental | terp-rs | `nested_subdaos_instantiate2_on_terp` | `ICT_DAO_INIT2=1 TERP_IMAGE_REPO TERP_IMAGE_VERSION` | cargo test -p dao-foundation-suite --test dao_init2_chain --offline -- --ignored --nocapture |
| experimental | terp-rs | `polytone_two_chains` | `ICT_POLYTONE=1 TERP_IMAGE_REPO TERP_IMAGE_VERSION` | cargo test -p dao-foundation-suite --test polytone_two_chains --offline -- --ignored --nocapture |
| experimental | terp-rs | `artifact_stack live` | `TERP_IMAGE_REPO TERP_IMAGE_VERSION` | cargo test -p terp-orch --features stack,ict --test artifact_stack live --offline -- --ignored --nocapture |
| curated | terp-core | `tests/tsh/upgrade/v63.sh` | `TERP_IMAGE_REPO TERP_IMAGE_VERSION` | v6.2.1 snapshot through v6.3 into v6.4. Binaries are the local ELFs, not a pinned tag. |
| experimental | dao-contracts | `dao_testing` | `TERP_IMAGE_REPO TERP_IMAGE_VERSION` | stores dao-contracts artifacts (core, proposal, voting, cw4, stake) and instantiates cw4_group |
| experimental | terp-core | `abstract_account` | `TERP_IMAGE_REPO TERP_IMAGE_VERSION` | x/smart-account params and authenticator query on the terp image |
