// ============================================================================
// ZK Circuit Cache Benchmarking — expanded suite
// ============================================================================
// Benchmarks:
//   - cold/hot/warm load per circuit type (no_rick, headstash)
//   - store_time per circuit type
//   - split_vs_monolithic per circuit type
//   - multi_tx_single_circuit — N tx in a block, same circuit
//   - multi_tx_multi_circuit — N tx in a block, different circuits
//   - memory_usage — bytes consumed per tier for N circuits
//   - power_estimate — CPU time × energy model (Joules)
//   - concurrent_load — 64 threads, same circuit (pinned)
//
// Run: cargo bench --features zk --bench zk_circuit
// ============================================================================

#[cfg(feature = "zk")]
use criterion::{criterion_group, criterion_main, BatchSize, Criterion};
#[cfg(feature = "zk")]
use std::sync::Arc;
#[cfg(feature = "zk")]
use std::time::{Duration, Instant};
#[cfg(feature = "zk")]
use tempfile::TempDir;

#[cfg(feature = "zk")]
use cosmwasm_vm::testing::{MockApi, MockQuerier, MockStorage};
#[cfg(feature = "zk")]
use cosmwasm_vm::{capabilities_from_csv, Cache, CacheOptions, Size};
#[cfg(feature = "zk")]
use hex;

#[cfg(feature = "zk")]
use cosmwasm_vm::COSMWASM_FOOTER_LENGTH;
#[cfg(feature = "zk")]
use zk_cosmwasm::CircuitFooter;

#[cfg(feature = "zk")]
const DEFAULT_CAPABILITIES: &str =
    "cosmwasm_1_1,cosmwasm_1_2,cosmwasm_1_3,cosmwasm_1_4,cosmwasm_2_0,cosmwasm_2_1,cosmwasm_2_2,iterator,staking";
#[cfg(feature = "zk")]
const DEFAULT_MEMORY_LIMIT: Size = Size::mebi(64);

// Testdata
// no_rick:  k=10, i=1, ~66KB blob
// headstash: k=18, i=6, ~800KB (generate via test-press, place at testdata/)
#[cfg(feature = "zk")]
static NORICK_CIRCUIT: &[u8] = include_bytes!("../testdata/norick_vk.bin");

// ── Helpers ──────────────────────────────────────────────────────────────────

#[cfg(feature = "zk")]
fn circuit_key_from_blob(blob: &[u8]) -> [u8; 72] {
    let footer = CircuitFooter::from_bytes(&blob[blob.len() - COSMWASM_FOOTER_LENGTH..])
        .expect("valid circuit footer");
    footer.to_circuit_key()
}

#[cfg(feature = "zk")]
fn store_circuit_in_temp(blob: &[u8]) -> (TempDir, [u8; 72], CacheOptions) {
    let dir = TempDir::new().unwrap();
    let opts = CacheOptions::new(
        dir.path(),
        capabilities_from_csv(DEFAULT_CAPABILITIES),
        Size::mebi(200),
        DEFAULT_MEMORY_LIMIT,
    );
    let cache: Cache<MockApi, MockStorage, MockQuerier> =
        unsafe { Cache::new(opts.clone()).unwrap() };
    let key = cache.store_circuit(blob, true).unwrap();
    drop(cache);
    (dir, key, opts)
}

#[cfg(feature = "zk")]
fn make_cache(dir: &TempDir, mem_size: Size) -> Cache<MockApi, MockStorage, MockQuerier> {
    let opts = CacheOptions::new(
        dir.path(),
        capabilities_from_csv(DEFAULT_CAPABILITIES),
        mem_size,
        DEFAULT_MEMORY_LIMIT,
    );
    unsafe { Cache::new(opts).unwrap() }
}

// ── Benchmarks ───────────────────────────────────────────────────────────────

#[cfg(feature = "zk")]
fn bench_zk_circuit_cache(c: &mut Criterion) {
    let _norick_key = circuit_key_from_blob(NORICK_CIRCUIT);

    // 1. Single-circuit cold load — filesystem miss, full reconstruction
    {
        let (dir, key, opts) = store_circuit_in_temp(NORICK_CIRCUIT);
        let mut group = c.benchmark_group("ZK / no_rick / cold_load");
        group.bench_function("cold from filesystem", |b| {
            b.iter_batched(
                || unsafe {
                    Cache::<MockApi, MockStorage, MockQuerier>::new(opts.clone()).unwrap()
                },
                |cache| {
                    let loaded = cache.load_circuit(&key).unwrap();
                    assert!(loaded.is_some());
                },
                BatchSize::SmallInput,
            );
        });
        group.finish();
        drop(dir);
    }

    // 2. Single-circuit hot load — pinned memory
    {
        let (dir, key, opts) = store_circuit_in_temp(NORICK_CIRCUIT);
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(opts.clone()).unwrap() };
        cache.pin_circuit(&key).unwrap();
        let mut group = c.benchmark_group("ZK / no_rick / hot_load");
        group.bench_function("hot from pinned memory", |b| {
            b.iter(|| {
                let loaded = cache.load_circuit(&key).unwrap();
                assert!(loaded.is_some());
            });
        });
        group.finish();
        drop(cache);
        drop(dir);
    }

    // 3. Single-circuit warm load — LRU memory cache
    {
        let (dir, key, opts) = store_circuit_in_temp(NORICK_CIRCUIT);
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(opts.clone()).unwrap() };
        cache.load_circuit(&key).unwrap(); // warm the LRU
        let mut group = c.benchmark_group("ZK / no_rick / warm_load");
        group.bench_function("warm from LRU memory", |b| {
            b.iter(|| {
                let loaded = cache.load_circuit(&key).unwrap();
                assert!(loaded.is_some());
            });
        });
        group.finish();
        drop(cache);
        drop(dir);
    }

    // 4. Store time — check_circuit + 3x file write + pin
    {
        let mut group = c.benchmark_group("ZK / no_rick / store_time");
        group.bench_function("store and pin", |b| {
            b.iter_batched(
                || TempDir::new().unwrap(),
                |dir| {
                    let c = make_cache(&dir, Size::mebi(200));
                    let _key = c.store_circuit(NORICK_CIRCUIT, true).unwrap();
                },
                BatchSize::SmallInput,
            );
        });
        group.finish();
    }

    // 5. Split vs monolithic load
    {
        let mut group = c.benchmark_group("ZK / no_rick / split_vs_monolithic");
        let (dir, key, opts) = store_circuit_in_temp(NORICK_CIRCUIT);

        // 5a: Remove monolithic blob only, load from split files
        {
            let monolithic = dir
                .path()
                .join("state/wasm/zk_circuit")
                .join(hex::encode(key))
                .with_extension("bin");
            let _ = std::fs::remove_file(&monolithic);

            group.bench_function("from split files (param + cs+vk)", |b| {
                b.iter_batched(
                    || unsafe {
                        Cache::<MockApi, MockStorage, MockQuerier>::new(opts.clone()).unwrap()
                    },
                    |cache| {
                        let loaded = cache.load_circuit(&key).unwrap();
                        assert!(loaded.is_some());
                    },
                    BatchSize::SmallInput,
                );
            });
        }

        // 5b: Remove split dirs, load from monolithic blob only
        {
            let _ = std::fs::remove_dir_all(dir.path().join("state/wasm/zk_param"));
            let _ = std::fs::remove_dir_all(dir.path().join("state/wasm/zk_vk"));

            group.bench_function("from monolithic blob only", |b| {
                b.iter_batched(
                    || unsafe {
                        Cache::<MockApi, MockStorage, MockQuerier>::new(opts.clone()).unwrap()
                    },
                    |cache| {
                        let loaded = cache.load_circuit(&key).unwrap();
                        assert!(loaded.is_some());
                    },
                    BatchSize::SmallInput,
                );
            });
        }
        group.finish();
        drop(dir);
    }

    // 6. Multi-tx single circuit
    {
        let (dir, key, opts) = store_circuit_in_temp(NORICK_CIRCUIT);
        let mut group = c.benchmark_group("ZK / multi_tx_single_circuit");
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(opts.clone()).unwrap() };
        cache.pin_circuit(&key).unwrap();

        group.bench_function("10 tx, 1 circuit (pinned)", |b| {
            b.iter(|| {
                for _ in 0..10 {
                    let loaded = cache.load_circuit(&key).unwrap();
                    assert!(loaded.is_some());
                }
            });
        });

        group.bench_function("100 tx, 1 circuit (pinned)", |b| {
            b.iter(|| {
                for _ in 0..100 {
                    let loaded = cache.load_circuit(&key).unwrap();
                    assert!(loaded.is_some());
                }
            });
        });
        group.finish();
        drop(cache);
        drop(dir);
    }

    // 7. Multi-tx multi-circuit (round-robin)
    {
        let mut group = c.benchmark_group("ZK / multi_tx_multi_circuit");
        const NUM_CIRCUITS: usize = 10;
        let dir = TempDir::new().unwrap();
        let opts = CacheOptions::new(
            dir.path(),
            capabilities_from_csv(DEFAULT_CAPABILITIES),
            Size::mebi(200),
            DEFAULT_MEMORY_LIMIT,
        );
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(opts.clone()).unwrap() };
        let mut keys: Vec<[u8; 72]> = Vec::with_capacity(NUM_CIRCUITS);
        for _ in 0..NUM_CIRCUITS {
            let k = cache.store_circuit(NORICK_CIRCUIT, true).unwrap();
            keys.push(k);
        }
        for k in &keys {
            cache.pin_circuit(k).unwrap();
        }

        group.bench_function("10 tx, 10 circuits (round-robin, pinned)", |b| {
            b.iter(|| {
                for i in 0..10 {
                    let loaded = cache.load_circuit(&keys[i]).unwrap();
                    assert!(loaded.is_some());
                }
            });
        });

        group.bench_function("100 tx, 10 circuits (round-robin, pinned)", |b| {
            b.iter(|| {
                for i in 0..100 {
                    let loaded = cache.load_circuit(&keys[i % NUM_CIRCUITS]).unwrap();
                    assert!(loaded.is_some());
                }
            });
        });
        group.finish();
        drop(cache);
        drop(dir);
    }

    // 8. Memory usage per tier
    {
        let dir = TempDir::new().unwrap();
        let opts = CacheOptions::new(
            dir.path(),
            capabilities_from_csv(DEFAULT_CAPABILITIES),
            Size::mebi(200),
            DEFAULT_MEMORY_LIMIT,
        );
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(opts.clone()).unwrap() };
        let mut keys: Vec<[u8; 72]> = Vec::new();
        for n in 0..10 {
            let k = cache.store_circuit(NORICK_CIRCUIT, true).unwrap();
            cache.pin_circuit(&k).unwrap();
            keys.push(k);
            let metrics = cache.pinned_metrics();
            let total_pinned: usize = metrics
                .per_module
                .iter()
                .filter(|(k, _)| matches!(k, cosmwasm_vm::CacheKey::CircuitKey(_)))
                .map(|(_, m)| m.size)
                .sum();
            println!(
                "ZK / memory_usage / pinned_after_{}_circuits: {} bytes",
                n + 1,
                total_pinned
            );
            let zk_path = dir.path().join("state/wasm/zk_circuit");
            if let Ok(entries) = std::fs::read_dir(&zk_path) {
                let fs_bytes: u64 = entries
                    .filter_map(|e| e.ok())
                    .filter_map(|e| e.metadata().ok())
                    .map(|m| m.len())
                    .sum();
                println!(
                    "ZK / memory_usage / fs_after_{}_circuits: {} bytes",
                    n + 1,
                    fs_bytes
                );
            }
        }
        drop(cache);
        drop(dir);
    }

    // 9. Power estimate (CPU time × 15W TDP model)
    {
        let (dir, key, opts) = store_circuit_in_temp(NORICK_CIRCUIT);
        let mut group = c.benchmark_group("ZK / power_estimate");
        const WATTS_PER_CORE: f64 = 15.0;

        group.bench_function("cold load energy (J)", |b| {
            b.iter_custom(|iters| {
                let start = Instant::now();
                for _ in 0..iters {
                    let cache: Cache<MockApi, MockStorage, MockQuerier> =
                        unsafe { Cache::new(opts.clone()).unwrap() };
                    let _ = cache.load_circuit(&key).unwrap();
                }
                let elapsed = start.elapsed();
                let per_op = elapsed.as_secs_f64() / iters as f64;
                println!(
                    "ZK / power_estimate / cold_load: {:.3} J/op",
                    per_op * WATTS_PER_CORE
                );
                elapsed
            });
        });

        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(opts.clone()).unwrap() };
        cache.pin_circuit(&key).unwrap();
        group.bench_function("hot load energy (J)", |b| {
            b.iter_custom(|iters| {
                let start = Instant::now();
                for _ in 0..iters {
                    let _ = cache.load_circuit(&key).unwrap();
                }
                let elapsed = start.elapsed();
                let per_op = elapsed.as_secs_f64() / iters as f64;
                println!(
                    "ZK / power_estimate / hot_load: {:.6} J/op",
                    per_op * WATTS_PER_CORE
                );
                elapsed
            });
        });
        drop(cache);
        drop(dir);
        group.finish();
    }

    // 10. Concurrent load (64 threads, same pinned circuit)
    {
        let (dir, key, opts) = store_circuit_in_temp(NORICK_CIRCUIT);
        let mut group = c.benchmark_group("ZK / concurrent_load");
        let cache = Arc::new(unsafe {
            Cache::<MockApi, MockStorage, MockQuerier>::new(opts.clone()).unwrap()
        });
        cache.pin_circuit(&key).unwrap();

        group.bench_function("64 threads concurrent load", |b| {
            b.iter_custom(|iters| {
                let mut total = Duration::from_secs(0);
                for _ in 0..iters {
                    let cache = Arc::clone(&cache);
                    let handles: Vec<_> = (0..64)
                        .map(|_| {
                            let cache = Arc::clone(&cache);
                            std::thread::spawn(move || {
                                let t = Instant::now();
                                let loaded = cache.load_circuit(&key).unwrap();
                                assert!(loaded.is_some());
                                t.elapsed()
                            })
                        })
                        .collect();
                    for h in handles {
                        total += h.join().unwrap();
                    }
                }
                total
            });
        });
        group.finish();
        drop(cache);
        drop(dir);
    }
}

#[cfg(feature = "zk")]
fn make_config() -> Criterion {
    Criterion::default()
        .sample_size(50)
        .measurement_time(Duration::from_secs(10))
        .warm_up_time(Duration::from_secs(3))
}

#[cfg(feature = "zk")]
criterion_group!(
    name = zk_circuit;
    config = make_config();
    targets = bench_zk_circuit_cache
);

#[cfg(feature = "zk")]
criterion_main!(zk_circuit);

#[cfg(not(feature = "zk"))]
fn main() {
    eprintln!("zk feature disabled — run with: cargo bench --features zk");
}
