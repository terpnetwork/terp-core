//! Criterion benches for host ZK verify — feeds gas calibration.
//!
//! ```text
//! cargo bench -p zk-cosmwasm --features bn254 --bench verify_gas
//! ```

use criterion::{black_box, criterion_group, criterion_main, Criterion};
use std::path::PathBuf;
use zk_cosmwasm::{AnyInstance, AnyVerifyingKey, Proof};

fn testdata() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("testdata")
}

fn bench_square_verify(c: &mut Criterion) {
    let td = testdata();
    let Ok(circuit) = std::fs::read(td.join("square_vk.bin")) else {
        eprintln!("skip square_verify: missing fixtures");
        return;
    };
    let Ok(proof_bytes) = std::fs::read(td.join("square_proof.bin")) else {
        return;
    };
    let Ok(public) = std::fs::read(td.join("square_public.bin")) else {
        return;
    };

    let vk = AnyVerifyingKey::try_from(circuit.as_slice()).expect("vk");
    let inst = AnyInstance::try_from_bytes(vk.curve_id() as u32, &public).expect("inst");
    let proof = Proof::new(proof_bytes);

    let mut group = c.benchmark_group("zk_verify/square_groth16");
    group.bench_function("verify", |b| {
        b.iter(|| {
            let r = vk.verify(black_box(&proof), black_box(std::slice::from_ref(&inst)));
            assert!(r.is_ok());
        });
    });
    group.finish();
}

fn bench_norick_load(c: &mut Criterion) {
    let candidates = [
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../zk-wasmvm/testdata/norick_vk.bin"),
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("testdata/norick_vk.bin"),
    ];
    let mut blob = None;
    for p in &candidates {
        if let Ok(b) = std::fs::read(p) {
            blob = Some(b);
            break;
        }
    }
    let Some(blob) = blob else {
        eprintln!("skip norick_load: fixture not found");
        return;
    };

    let mut group = c.benchmark_group("zk_verify/norick_vk_load");
    group.bench_function("AnyVerifyingKey::try_from", |b| {
        b.iter(|| {
            let vk = AnyVerifyingKey::try_from(black_box(blob.as_slice()));
            assert!(vk.is_ok());
        });
    });
    group.finish();
}

criterion_group!(benches, bench_square_verify, bench_norick_load);
criterion_main!(benches);
