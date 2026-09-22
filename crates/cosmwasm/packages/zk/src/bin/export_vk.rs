//! Export circuit VK bytes to the CosmWasm VM's CircuitFooter format.
//!
//! Takes pre-serialized params and VK body bytes (produced by the vote-sdk's
//! halo2 0.3 .write() methods) and wraps them with the 80-byte CircuitFooter
//! so they can be loaded by AnyVerifyingKey::from_bytes().
//!
//! Usage:
//!   cargo run --bin export_vk -- toy          --output /tmp/toy_vk.bin
//!   cargo run --bin export_vk -- delegation   --params p.bin --vk-body v.bin --output /tmp/del_vk.bin
//!   cargo run --bin export_vk -- vote_proof   --params p.bin --vk-body v.bin --output /tmp/vp_vk.bin
//!   cargo run --bin export_vk -- share_reveal --params p.bin --vk-body v.bin --output /tmp/sr_vk.bin

use std::path::PathBuf;

use clap::Parser;
use halo2_proofs::{
    pasta::{EqAffine, Fp},
    plonk::{keygen_vk, Circuit},
    poly::commitment::Params,
};
use zk_cosmwasm::curves::{VoteCircuitId, VoteVerifyingKey};

#[derive(Parser)]
#[command(
    name = "export_vk",
    about = "Export circuit VK to CircuitFooter format"
)]
struct Args {
    circuit: String,
    #[arg(short, long, default_value = "/tmp/vk.bin")]
    output: PathBuf,
    #[arg(long)]
    params: Option<PathBuf>,
    #[arg(long)]
    vk_body: Option<PathBuf>,
}

fn export_toy(output: &PathBuf) {
    println!("Exporting toy circuit VK...");

    let params = Params::<EqAffine>::new(4);
    let empty_circuit = ToyCircuit::<Fp> {
        constant: Fp::from(7),
        a: halo2_proofs::circuit::Value::unknown(),
        b: halo2_proofs::circuit::Value::unknown(),
    };
    let vk = keygen_vk(&params, &empty_circuit).expect("keygen_vk");

    let mut param_bytes = Vec::new();
    params.write(&mut param_bytes).expect("params.write");

    let mut vk_body = Vec::new();
    vk.cs().write(&mut vk_body).expect("cs.write");
    vk.write(&mut vk_body).expect("vk.write");

    // Toy: curve_id=0 (Pasta, generic), k=4, i=1
    let vote_vk = VoteVerifyingKey::from_voting_circuit_vk(
        VoteCircuitId::try_from(1).unwrap(),
        param_bytes,
        vk_body,
        4,
        1,
    );

    let mut bytes = Vec::new();
    bytes.extend_from_slice(&vote_vk.params_bytes);
    bytes.extend_from_slice(&vote_vk.vk_body_bytes);
    bytes.extend_from_slice(&vote_vk.footer.to_bytes());
    std::fs::write(output, &bytes).expect("write output");
    println!("Wrote {} bytes to {}", bytes.len(), output.display());
    println!("  curve_id=0 (Pasta, generic Plonkish)");
    println!("  k=4, i=1");
}

fn export_from_files(
    circuit: &str,
    output: &PathBuf,
    params_path: &PathBuf,
    vk_body_path: &PathBuf,
) {
    let param_bytes = std::fs::read(params_path).expect("read params file");
    let vk_body_bytes = std::fs::read(vk_body_path).expect("read vk body file");

    let (circuit_id, k, i) = match circuit {
        "delegation" => (VoteCircuitId::Delegation, 14u8, 14u8),
        "vote_proof" => (VoteCircuitId::VoteCommitment, 14u8, 11u8),
        "share_reveal" => (VoteCircuitId::ShareReveal, 14u8, 9u8),
        other => panic!("Unknown circuit: {other}"),
    };

    let vote_vk =
        VoteVerifyingKey::from_voting_circuit_vk(circuit_id, param_bytes, vk_body_bytes, k, i);

    let mut bytes = Vec::new();
    bytes.extend_from_slice(&vote_vk.params_bytes);
    bytes.extend_from_slice(&vote_vk.vk_body_bytes);
    bytes.extend_from_slice(&vote_vk.footer.to_bytes());
    std::fs::write(output, &bytes).expect("write output");
    println!("Wrote {} bytes to {}", bytes.len(), output.display());
    println!("  curve_id={}", vote_vk.footer.curve_id);
    println!("  k={}, i={}", k, i);
}

// ── Toy circuit (self-contained, no vote-sdk dependency) ─────────────────

use group::ff::Field;
use halo2_proofs::{
    circuit::{Chip, Layouter, SimpleFloorPlanner, Value},
    plonk::{Advice, Column, ConstraintSystem, Error, Instance, Selector},
    poly::Rotation,
};
use std::marker::PhantomData;

trait NumericInstructions<F: Field>: Chip<F> {
    type Num;
    fn load_private(&self, layouter: impl Layouter<F>, a: Value<F>) -> Result<Self::Num, Error>;
    fn mul(
        &self,
        layouter: impl Layouter<F>,
        a: Self::Num,
        b: Self::Num,
    ) -> Result<Self::Num, Error>;
    fn expose_public(
        &self,
        layouter: impl Layouter<F>,
        num: Self::Num,
        row: usize,
    ) -> Result<(), Error>;
}

#[derive(Clone, Debug)]
struct FieldConfig {
    advice: [Column<Advice>; 2],
    instance: Column<Instance>,
    s_mul: Selector,
}

struct FieldChip<F: Field> {
    config: FieldConfig,
    _marker: PhantomData<F>,
}

impl<F: Field> Chip<F> for FieldChip<F> {
    type Config = FieldConfig;
    type Loaded = ();
    fn config(&self) -> &Self::Config {
        &self.config
    }
    fn loaded(&self) -> &Self::Loaded {
        &()
    }
}

#[derive(Clone)]
struct Number<F: Field>(halo2_proofs::circuit::AssignedCell<F, F>);

#[derive(Default)]
struct ToyCircuit<F: Field> {
    constant: F,
    a: Value<F>,
    b: Value<F>,
}

impl<F: Field> Circuit<F> for ToyCircuit<F> {
    type Config = FieldConfig;
    type FloorPlanner = SimpleFloorPlanner;
    fn without_witnesses(&self) -> Self {
        Self::default()
    }
    fn configure(meta: &mut ConstraintSystem<F>) -> Self::Config {
        let advice = [meta.advice_column(), meta.advice_column()];
        let instance = meta.instance_column();
        let constant = meta.fixed_column();
        meta.enable_equality(instance);
        meta.enable_constant(constant);
        for col in &advice {
            meta.enable_equality(*col);
        }
        let s_mul = meta.selector();
        meta.create_gate("mul", |meta| {
            vec![
                meta.query_selector(s_mul)
                    * (meta.query_advice(advice[0], Rotation::cur())
                        * meta.query_advice(advice[1], Rotation::cur())
                        - meta.query_advice(advice[0], Rotation::next())),
            ]
        });
        FieldConfig {
            advice,
            instance,
            s_mul,
        }
    }
    fn synthesize(&self, _config: Self::Config, _layouter: impl Layouter<F>) -> Result<(), Error> {
        Ok(())
    }
}

fn main() {
    let args = Args::parse();
    match args.circuit.to_lowercase().as_str() {
        "toy" => export_toy(&args.output),
        _ => {
            let params = args.params.expect("--params required for real circuits");
            let vk_body = args.vk_body.expect("--vk-body required for real circuits");
            export_from_files(&args.circuit, &args.output, &params, &vk_body);
        }
    }
}
