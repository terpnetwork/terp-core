use criterion::{black_box, criterion_group, criterion_main, BatchSize, Criterion};

use rand::Rng;
use std::sync::Arc;
use std::time::{Duration, SystemTime};
use std::{fs, thread};
use tempfile::TempDir;

use cosmwasm_std::{coins, Checksum, Empty};
use cosmwasm_vm::testing::{
    mock_backend, mock_env, mock_info, mock_instance_options, MockApi, MockQuerier, MockStorage,
};
use cosmwasm_vm::{
    call_execute, call_instantiate, capabilities_from_csv, Cache, CacheOptions, Instance,
    InstanceOptions, Size, VmError,
};

#[cfg(feature = "zk")]
use {
    cosmwasm_vm::CachedCircuit, cosmwasm_vm::COSMWASM_FOOTER_LENGTH, zk_cosmwasm::CircuitFooter,
};

// Instance
const DEFAULT_MEMORY_LIMIT: Size = Size::mebi(64);
const DEFAULT_GAS_LIMIT: u64 = 1_000_000_000; // ~1ms
const DEFAULT_INSTANCE_OPTIONS: InstanceOptions = InstanceOptions {
    gas_limit: DEFAULT_GAS_LIMIT,
};
const HIGH_GAS_LIMIT: u64 = 20_000_000_000_000; // ~20s, allows many calls on one instance
const MEDIUM_GAS_LIMIT: u64 = 1_000_000_000_000; // ~1s

// Cache
const MEMORY_CACHE_SIZE: Size = Size::mebi(200);

// Multithreaded get_instance benchmark
const INSTANTIATION_THREADS: usize = 128;
const CONTRACTS: u64 = 10;

const DEFAULT_CAPABILITIES: &str = "cosmwasm_1_1,cosmwasm_1_2,cosmwasm_1_3,cosmwasm_1_4,cosmwasm_2_0,cosmwasm_2_1,cosmwasm_2_2,iterator,staking";
static HACKATOM: &[u8] = include_bytes!("../testdata/hackatom.wasm");
static CYBERPUNK: &[u8] = include_bytes!("../testdata/cyberpunk.wasm");

#[cfg(feature = "zk")]
static NORICK_CIRCUIT: &[u8] = include_bytes!("../testdata/norick_vk.bin");

static BENCH_CONTRACTS: &[&str] = &[
    "cyberpunk_rust170.wasm",
    "cyberpunk.wasm",
    "floaty_1.0.wasm",
    "floaty_1.2.wasm",
    "floaty_2.0.wasm",
    "hackatom_1.0.wasm",
    "hackatom_1.2.wasm",
    "hackatom.wasm",
];

fn bench_instance(c: &mut Criterion) {
    let mut group = c.benchmark_group("Instance");

    group.bench_function("compile and instantiate", |b| {
        b.iter(|| {
            let backend = mock_backend(&[]);
            let (instance_options, memory_limit) = mock_instance_options();
            let _instance =
                Instance::from_code(HACKATOM, backend, instance_options, memory_limit).unwrap();
        });
    });

    group.bench_function("execute init", |b| {
        let backend = mock_backend(&[]);
        let much_gas: InstanceOptions = InstanceOptions {
            gas_limit: HIGH_GAS_LIMIT,
        };
        let mut instance =
            Instance::from_code(HACKATOM, backend, much_gas, Some(DEFAULT_MEMORY_LIMIT)).unwrap();

        b.iter(|| {
            let info = mock_info(&instance.api().addr_make("creator"), &coins(1000, "earth"));
            let verifier = instance.api().addr_make("verifies");
            let beneficiary = instance.api().addr_make("benefits");
            let msg = format!(r#"{{"verifier": "{verifier}", "beneficiary": "{beneficiary}"}}"#);
            let contract_result = call_instantiate::<_, _, _, Empty>(
                &mut instance,
                &mock_env(),
                &info,
                msg.as_bytes(),
            )
            .unwrap();
            assert!(contract_result.into_result().is_ok());
        });
    });

    group.bench_function("execute (release)", |b| {
        let backend = mock_backend(&[]);
        let much_gas: InstanceOptions = InstanceOptions {
            gas_limit: HIGH_GAS_LIMIT,
        };
        let mut instance =
            Instance::from_code(HACKATOM, backend, much_gas, Some(DEFAULT_MEMORY_LIMIT)).unwrap();

        let info = mock_info(&instance.api().addr_make("creator"), &coins(1000, "earth"));
        let verifier = instance.api().addr_make("verifies");
        let beneficiary = instance.api().addr_make("benefits");
        let msg = format!(r#"{{"verifier": "{verifier}", "beneficiary": "{beneficiary}"}}"#);
        let contract_result =
            call_instantiate::<_, _, _, Empty>(&mut instance, &mock_env(), &info, msg.as_bytes())
                .unwrap();
        assert!(contract_result.into_result().is_ok());

        b.iter(|| {
            let info = mock_info(&verifier, &coins(15, "earth"));
            let msg = br#"{"release":{"denom":"earth"}}"#;
            let contract_result =
                call_execute::<_, _, _, Empty>(&mut instance, &mock_env(), &info, msg).unwrap();
            assert!(contract_result.into_result().is_ok());
        });
    });

    group.bench_function("execute (argon2)", |b| {
        let backend = mock_backend(&[]);
        let much_gas: InstanceOptions = InstanceOptions {
            gas_limit: HIGH_GAS_LIMIT,
        };
        let mut instance =
            Instance::from_code(CYBERPUNK, backend, much_gas, Some(DEFAULT_MEMORY_LIMIT)).unwrap();

        let info = mock_info("creator", &coins(1000, "earth"));
        let contract_result =
            call_instantiate::<_, _, _, Empty>(&mut instance, &mock_env(), &info, b"{}").unwrap();
        assert!(contract_result.into_result().is_ok());

        let mut gas_used = 0;
        b.iter(|| {
            let gas_before = instance.get_gas_left();
            let info = mock_info("hasher", &[]);
            let msg = br#"{"argon2":{"mem_cost":256,"time_cost":3}}"#;
            let contract_result =
                call_execute::<_, _, _, Empty>(&mut instance, &mock_env(), &info, msg).unwrap();
            assert!(contract_result.into_result().is_ok());
            gas_used = gas_before - instance.get_gas_left();
        });
        println!("Gas used: {gas_used}");
    });

    group.bench_function("execute (infinite loop)", |b| {
        let backend = mock_backend(&[]);
        let medium_gas: InstanceOptions = InstanceOptions {
            gas_limit: MEDIUM_GAS_LIMIT,
        };
        let mut instance =
            Instance::from_code(CYBERPUNK, backend, medium_gas, Some(DEFAULT_MEMORY_LIMIT))
                .unwrap();

        let info = mock_info("creator", &coins(1000, "earth"));
        let contract_result =
            call_instantiate::<_, _, _, Empty>(&mut instance, &mock_env(), &info, b"{}").unwrap();
        assert!(contract_result.into_result().is_ok());

        let mut gas_used = 0;
        b.iter_batched(
            || {
                // setup new instance for each iteration because cpu loop will consume all gas
                Instance::from_code(
                    CYBERPUNK,
                    mock_backend(&[]),
                    medium_gas,
                    Some(DEFAULT_MEMORY_LIMIT),
                )
                .unwrap()
            },
            |mut instance| {
                let gas_before = instance.get_gas_left();
                let info = mock_info("hasher", &[]);
                let msg = br#"{"cpu_loop":{}}"#;

                let vm_result =
                    call_execute::<_, _, _, Empty>(&mut instance, &mock_env(), &info, msg);

                assert!(matches!(vm_result, Err(VmError::GasDepletion { .. })));
                gas_used = gas_before - instance.get_gas_left();
            },
            BatchSize::SmallInput,
        );
        println!("Gas used: {gas_used}");
    });

    group.finish();
}

fn bench_cache(c: &mut Criterion) {
    let mut group = c.benchmark_group("Cache");

    let temp_dir = TempDir::new().unwrap();
    let options = CacheOptions::new(
        temp_dir.path(),
        capabilities_from_csv(DEFAULT_CAPABILITIES),
        MEMORY_CACHE_SIZE,
        DEFAULT_MEMORY_LIMIT,
    );

    group.bench_function("save wasm", |b| {
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(options.clone()).unwrap() };

        b.iter(|| {
            let result = cache.store_code(HACKATOM, true, true);
            assert!(result.is_ok());
        });
    });

    group.bench_function("load wasm", |b| {
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(options.clone()).unwrap() };
        let checksum = cache.store_code(HACKATOM, true, true).unwrap();

        b.iter(|| {
            let result = cache.load_wasm(&checksum);
            assert!(result.is_ok());
        });
    });

    group.bench_function("load wasm unchecked", |b| {
        let options = options.clone();
        let mut cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(options).unwrap() };
        cache.set_module_unchecked(true);
        let checksum = cache.store_code(HACKATOM, true, true).unwrap();

        b.iter(|| {
            let result = cache.load_wasm(&checksum);
            assert!(result.is_ok());
        });
    });

    for contract_name in BENCH_CONTRACTS {
        let contract_wasm = fs::read(format!("testdata/{contract_name}")).unwrap();
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(options.clone()).unwrap() };
        let checksum = cache.store_code(&contract_wasm, true, true).unwrap();

        group.bench_function(format!("analyze_{contract_name}"), |b| {
            b.iter(|| {
                let result = cache.analyze(&checksum);
                assert!(result.is_ok());
            });
        });
    }

    let temp_dir = TempDir::new().unwrap();
    group.bench_function("instantiate from fs", |b| {
        let non_memcache = CacheOptions::new(
            temp_dir.path(),
            capabilities_from_csv(DEFAULT_CAPABILITIES),
            Size::new(0),
            DEFAULT_MEMORY_LIMIT,
        );
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(non_memcache).unwrap() };
        let checksum = cache.store_code(HACKATOM, true, true).unwrap();

        b.iter(|| {
            let _ = cache
                .get_instance(&checksum, mock_backend(&[]), DEFAULT_INSTANCE_OPTIONS)
                .unwrap();
            assert_eq!(cache.stats().hits_pinned_memory_cache, 0);
            assert_eq!(cache.stats().hits_memory_cache, 0);
            assert!(cache.stats().hits_fs_cache >= 1);
            assert_eq!(cache.stats().misses, 0);
        });
    });

    let temp_dir = TempDir::new().unwrap();
    group.bench_function("instantiate from fs unchecked", |b| {
        let non_memcache = CacheOptions::new(
            temp_dir.path(),
            capabilities_from_csv(DEFAULT_CAPABILITIES),
            Size::new(0),
            DEFAULT_MEMORY_LIMIT,
        );
        let mut cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(non_memcache).unwrap() };
        cache.set_module_unchecked(true);
        let checksum = cache.store_code(HACKATOM, true, true).unwrap();

        b.iter(|| {
            let _ = cache
                .get_instance(&checksum, mock_backend(&[]), DEFAULT_INSTANCE_OPTIONS)
                .unwrap();
            assert_eq!(cache.stats().hits_pinned_memory_cache, 0);
            assert_eq!(cache.stats().hits_memory_cache, 0);
            assert!(cache.stats().hits_fs_cache >= 1);
            assert_eq!(cache.stats().misses, 0);
        });
    });

    group.bench_function("instantiate from memory", |b| {
        let checksum = Checksum::generate(HACKATOM);
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(options.clone()).unwrap() };
        // Load into memory
        cache
            .get_instance(&checksum, mock_backend(&[]), DEFAULT_INSTANCE_OPTIONS)
            .unwrap();

        b.iter(|| {
            let backend = mock_backend(&[]);
            let _ = cache
                .get_instance(&checksum, backend, DEFAULT_INSTANCE_OPTIONS)
                .unwrap();
            assert_eq!(cache.stats().hits_pinned_memory_cache, 0);
            assert!(cache.stats().hits_memory_cache >= 1);
            assert_eq!(cache.stats().hits_fs_cache, 1);
            assert_eq!(cache.stats().misses, 0);
        });
    });

    group.bench_function("instantiate from pinned memory", |b| {
        let checksum = Checksum::generate(HACKATOM);
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(options.clone()).unwrap() };
        // Load into pinned memory
        cache.pin(&checksum).unwrap();

        b.iter(|| {
            let backend = mock_backend(&[]);
            let _ = cache
                .get_instance(&checksum, backend, DEFAULT_INSTANCE_OPTIONS)
                .unwrap();
            assert_eq!(cache.stats().hits_memory_cache, 0);
            assert!(cache.stats().hits_pinned_memory_cache >= 1);
            assert_eq!(cache.stats().hits_fs_cache, 1);
            assert_eq!(cache.stats().misses, 0);
        });
    });

    group.finish();
}

fn bench_instance_threads(c: &mut Criterion) {
    let temp_dir = TempDir::new().unwrap();
    c.bench_function("multithreaded get_instance", |b| {
        let options = CacheOptions::new(
            temp_dir.path(),
            capabilities_from_csv(DEFAULT_CAPABILITIES),
            MEMORY_CACHE_SIZE,
            DEFAULT_MEMORY_LIMIT,
        );

        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(options).unwrap() };
        let cache = Arc::new(cache);

        // Find sub-sequence helper
        fn find_subsequence(haystack: &[u8], needle: &[u8]) -> Option<usize> {
            haystack
                .windows(needle.len())
                .position(|window| window == needle)
        }

        // Offset to the i32.const (0x41) 15731626 (0xf00baa) (unsigned leb128 encoded) instruction
        // data we want to replace
        let query_int_data = b"\x41\xaa\x97\xc0\x07";
        let offset = find_subsequence(HACKATOM, query_int_data).unwrap() + 1;

        let mut leb128_buf = [0; 4];
        let mut contract = HACKATOM.to_vec();

        let mut random_checksum = || {
            let mut writable = &mut leb128_buf[..];

            // Generates a random number in the range of a 4-byte unsigned leb128 encoded number
            let r = rand::thread_rng().gen_range(2097152..2097152 + CONTRACTS);

            leb128::write::unsigned(&mut writable, r).expect("Should write number");

            // Splice data in contract
            contract.splice(offset..offset + leb128_buf.len(), leb128_buf);

            cache.store_code(contract.as_slice(), true, true).unwrap()
        };

        b.iter_custom(|iters| {
            let mut res = Duration::from_secs(0);
            for _ in 0..iters {
                let mut durations: Vec<_> = (0..INSTANTIATION_THREADS)
                    .map(|_id| {
                        let cache = Arc::clone(&cache);
                        let checksum = random_checksum();

                        thread::spawn(move || {
                            // Perform measurement internally
                            let t = SystemTime::now();
                            black_box(
                                cache
                                    .get_instance(
                                        &checksum,
                                        mock_backend(&[]),
                                        DEFAULT_INSTANCE_OPTIONS,
                                    )
                                    .unwrap(),
                            );
                            t.elapsed().unwrap()
                        })
                    })
                    .collect::<Vec<_>>()
                    .into_iter()
                    .map(|handle| handle.join().unwrap())
                    .collect(); // join threads, collect durations

                // Calculate median thread duration
                durations.sort_unstable();
                res += durations[durations.len() / 2];
            }
            res
        });
    });
}

fn bench_combined(c: &mut Criterion) {
    let mut group = c.benchmark_group("Combined");

    let temp_dir = TempDir::new().unwrap();
    let options = CacheOptions::new(
        temp_dir.path(),
        capabilities_from_csv("cosmwasm_1_1,cosmwasm_1_2,cosmwasm_1_3,iterator,staking"),
        MEMORY_CACHE_SIZE,
        DEFAULT_MEMORY_LIMIT,
    );

    // Store contracts for all benchmarks in this group
    let checksum: Checksum = {
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(options.clone()).unwrap() };
        cache.store_code(CYBERPUNK, true, true).unwrap()
    };

    group.bench_function("get instance from fs cache and execute", |b| {
        let mut non_memcache = options.clone();
        non_memcache.memory_cache_size_bytes = Size::kibi(0);

        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(non_memcache).unwrap() };

        b.iter(|| {
            let mut instance = cache
                .get_instance(&checksum, mock_backend(&[]), DEFAULT_INSTANCE_OPTIONS)
                .unwrap();
            assert_eq!(cache.stats().hits_pinned_memory_cache, 0);
            assert_eq!(cache.stats().hits_memory_cache, 0);
            assert!(cache.stats().hits_fs_cache >= 1);
            assert_eq!(cache.stats().misses, 0);

            let info = mock_info("guest", &[]);
            let msg = br#"{"noop":{}}"#;
            let contract_result =
                call_execute::<_, _, _, Empty>(&mut instance, &mock_env(), &info, msg).unwrap();
            contract_result.into_result().unwrap();
        });
    });

    group.bench_function("get instance from memory cache and execute", |b| {
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(options.clone()).unwrap() };

        // Load into memory
        cache
            .get_instance(&checksum, mock_backend(&[]), DEFAULT_INSTANCE_OPTIONS)
            .unwrap();

        b.iter(|| {
            let backend = mock_backend(&[]);
            let mut instance = cache
                .get_instance(&checksum, backend, DEFAULT_INSTANCE_OPTIONS)
                .unwrap();
            assert_eq!(cache.stats().hits_pinned_memory_cache, 0);
            assert!(cache.stats().hits_memory_cache >= 1);
            assert_eq!(cache.stats().hits_fs_cache, 1);
            assert_eq!(cache.stats().misses, 0);

            let info = mock_info("guest", &[]);
            let msg = br#"{"noop":{}}"#;
            let contract_result =
                call_execute::<_, _, _, Empty>(&mut instance, &mock_env(), &info, msg).unwrap();
            contract_result.into_result().unwrap();
        });
    });

    group.bench_function("get instance from pinned memory and execute", |b| {
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(options.clone()).unwrap() };

        // Load into pinned memory
        cache.pin(&checksum).unwrap();

        b.iter(|| {
            let backend = mock_backend(&[]);
            let mut instance = cache
                .get_instance(&checksum, backend, DEFAULT_INSTANCE_OPTIONS)
                .unwrap();
            assert_eq!(cache.stats().hits_memory_cache, 0);
            assert!(cache.stats().hits_pinned_memory_cache >= 1);
            assert_eq!(cache.stats().hits_fs_cache, 1);
            assert_eq!(cache.stats().misses, 0);

            let info = mock_info("guest", &[]);
            let msg = br#"{"noop":{}}"#;
            let contract_result =
                call_execute::<_, _, _, Empty>(&mut instance, &mock_env(), &info, msg).unwrap();
            contract_result.into_result().unwrap();
        });
    });

    group.finish();
}

// ============================================================================
// ZK Circuit Cache Benchmarks
// ============================================================================
// These benchmarks exercise the three-tier circuit cache (pinned → memory → fs)
// and measure cold-start reconstruction, warm/hot retrieval, store throughput,
// split vs monolithic format overhead, and concurrent load contention.
//
// Run with: cargo bench --features zk  (zk is in default features)
// ============================================================================

#[cfg(feature = "zk")]
fn bench_zk_circuit_cache(c: &mut Criterion) {
    // ------------------------------------------------------------------
    // Parse the NORICK circuit footer once so we can derive keys for the
    // store-then-load benchmarks.
    // ------------------------------------------------------------------
    let footer =
        CircuitFooter::from_bytes(&NORICK_CIRCUIT[NORICK_CIRCUIT.len() - COSMWASM_FOOTER_LENGTH..])
            .unwrap();
    let circuit_key: [u8; 72] = footer.to_circuit_key();

    // ------------------------------------------------------------------
    // 1.  Cold load —— no caches warmed.  Every load does a full
    //     deserialization from the zk_circuit monolithic blob (or
    //     split-file reconstruction).  This is the worst case.
    // ------------------------------------------------------------------
    {
        let mut group = c.benchmark_group("ZK Circuit / cold_load");

        // We must store the circuit into a temp cache first, then create
        // a FRESH cache for each iteration that has the files on disk
        // but no memory caches populated.
        let storage_dir = TempDir::new().unwrap();
        let seed_options = CacheOptions::new(
            storage_dir.path(),
            capabilities_from_csv(DEFAULT_CAPABILITIES),
            Size::mebi(200), // allow memory cache
            DEFAULT_MEMORY_LIMIT,
        );
        let seed_cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(seed_options.clone()).unwrap() };
        seed_cache.store_circuit(NORICK_CIRCUIT, true).unwrap();
        // Clean the LRU (fs cache still has the serialised module).
        // The pinned module stays — we need to pin + unpin to get a clean state.
        drop(seed_cache);

        group.bench_function("cold from filesystem", |b| {
            b.iter_batched(
                || {
                    // Fresh cache that reuses the same on-disk state dir but
                    // starts with empty memory tiers.
                    let fresh: Cache<MockApi, MockStorage, MockQuerier> =
                        unsafe { Cache::new(seed_options.clone()).unwrap() };
                    fresh
                },
                |cache| {
                    let loaded = cache.load_circuit(&circuit_key).unwrap();
                    assert!(loaded.is_some(), "cold load must return circuit");
                },
                BatchSize::SmallInput,
            );
        });
        group.finish();
    }

    // ------------------------------------------------------------------
    // 2.  Hot load —— circuit is pinned in the PinnedMemoryCache.
    //     Fastest path: a HashMap lookup + cheap clone of the Arc<vk>.
    // ------------------------------------------------------------------
    {
        let mut group = c.benchmark_group("ZK Circuit / hot_load");

        let temp = TempDir::new().unwrap();
        let options = CacheOptions::new(
            temp.path(),
            capabilities_from_csv(DEFAULT_CAPABILITIES),
            Size::mebi(200),
            DEFAULT_MEMORY_LIMIT,
        );
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(options).unwrap() };
        let key = cache.store_circuit(NORICK_CIRCUIT, true).unwrap();
        // pin_circuit is called automatically by store_circuit with persist=true,
        // but we verify it's already hot.
        assert!(cache.has_circuit(&key));

        group.bench_function("from pinned memory", |b| {
            b.iter(|| {
                let loaded = cache.load_circuit(&key).unwrap();
                assert!(loaded.is_some());
            });
        });
        group.finish();
    }

    // ------------------------------------------------------------------
    // 3.  Warm load —— circuit is in the InMemoryCache (LRU) but not
    //     pinned.  Slightly more expensive than hot due to weight
    //     tracking in CLruCache::get().
    // ------------------------------------------------------------------
    {
        let mut group = c.benchmark_group("ZK Circuit / warm_load");

        let temp = TempDir::new().unwrap();
        let options = CacheOptions::new(
            temp.path(),
            capabilities_from_csv(DEFAULT_CAPABILITIES),
            Size::mebi(200),
            DEFAULT_MEMORY_LIMIT,
        );
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(options).unwrap() };
        let key = cache.store_circuit(NORICK_CIRCUIT, true).unwrap();
        // Unpin to evict from pinned — circuit stays in memory LRU because
        // we just loaded through it.
        cache.unpin_circuit(&key).unwrap();

        group.bench_function("from memory LRU", |b| {
            b.iter(|| {
                let loaded = cache.load_circuit(&key).unwrap();
                assert!(loaded.is_some());
            });
        });
        group.finish();
    }

    // ------------------------------------------------------------------
    // 4.  Store time —— write a circuit blob to disk + pin to memory.
    //     Includes: footer parsing, checksum verification, three-way
    //     file write (param, vk_body, full circuit), and pin to pinned
    //     memory cache.
    // ------------------------------------------------------------------
    {
        let mut group = c.benchmark_group("ZK Circuit / store_time");

        let temp = TempDir::new().unwrap();
        let options = CacheOptions::new(
            temp.path(),
            capabilities_from_csv(DEFAULT_CAPABILITIES),
            Size::mebi(200),
            DEFAULT_MEMORY_LIMIT,
        );
        let _cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(options).unwrap() };

        // Use tempfile backing so each iter has a fresh directory.
        group.bench_function("store and pin", |b| {
            b.iter_batched(
                || TempDir::new().unwrap(),
                |dir| {
                    let opts = CacheOptions::new(
                        dir.path(),
                        capabilities_from_csv(DEFAULT_CAPABILITIES),
                        Size::mebi(200),
                        DEFAULT_MEMORY_LIMIT,
                    );
                    let c: Cache<MockApi, MockStorage, MockQuerier> =
                        unsafe { Cache::new(opts).unwrap() };
                    let _key = c.store_circuit(NORICK_CIRCUIT, true).unwrap();
                },
                BatchSize::SmallInput,
            );
        });
        group.finish();
    }

    // ------------------------------------------------------------------
    // 5.  Split vs monolithic —— measure the overhead of loading from
    //     the three split files (zk_param/ + zk_vk/ + zk_circuit/ for
    //     the footer) vs. the single monolithic zk_circuit blob.
    // ------------------------------------------------------------------
    {
        let mut group = c.benchmark_group("ZK Circuit / split_vs_monolithic");

        let temp = TempDir::new().unwrap();
        let options = CacheOptions::new(
            temp.path(),
            capabilities_from_csv(DEFAULT_CAPABILITIES),
            Size::new(0), // no LRU — force fs fallback
            DEFAULT_MEMORY_LIMIT,
        );
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(options).unwrap() };
        let key = cache.store_circuit(NORICK_CIRCUIT, true).unwrap();

        // Split path speed: load_circuit_with_path reads param + vk files
        // and reconstructs via from_split_bytes.
        group.bench_function("split-file reconstruction", |b| {
            // Remove the module cache entry so it falls through to split load
            // (but retain the zk_param/zk_vk/zk_circuit files).
            let loaded = cache.load_circuit(&key).unwrap();
            assert!(loaded.is_some());
            // load_circuit populates the fs_cache module, so subsequent
            // calls hit the deserialised module.  After `unpin` the
            // pinned copy is gone.
            cache.unpin_circuit(&key).unwrap();
            // Now warm but from fs cache serialised module.
            b.iter(|| {
                let loaded = cache.load_circuit(&key).unwrap();
                assert!(loaded.is_some());
            });
        });
        group.finish();
    }

    // ------------------------------------------------------------------
    // 6.  Concurrent load —— measure Arc<Mutex<CacheInner>> contention
    //     when N threads load the same cached circuit simultaneously.
    // ------------------------------------------------------------------
    {
        let mut group = c.benchmark_group("ZK Circuit / concurrent_load");

        let temp = TempDir::new().unwrap();
        let options = CacheOptions::new(
            temp.path(),
            capabilities_from_csv(DEFAULT_CAPABILITIES),
            Size::mebi(200),
            DEFAULT_MEMORY_LIMIT,
        );
        let cache: Arc<Cache<MockApi, MockStorage, MockQuerier>> =
            Arc::new(unsafe { Cache::new(options).unwrap() });
        let key = cache.store_circuit(NORICK_CIRCUIT, true).unwrap();

        const ZK_CONCURRENT_THREADS: usize = 64;

        group.bench_function("64 threads concurrent load", |b| {
            b.iter_custom(|iters| {
                let mut total = Duration::from_secs(0);
                for _ in 0..iters {
                    let t0 = SystemTime::now();
                    let handles: Vec<_> = (0..ZK_CONCURRENT_THREADS)
                        .map(|_| {
                            let cache = Arc::clone(&cache);
                            let k = key;
                            thread::spawn(move || {
                                black_box(cache.load_circuit(&k).unwrap());
                            })
                        })
                        .collect();
                    for h in handles {
                        h.join().unwrap();
                    }
                    total += t0.elapsed().unwrap();
                }
                total
            });
        });
        group.finish();
    }
}

fn make_config(measurement_time_s: u64) -> Criterion {
    Criterion::default()
        .without_plots()
        .measurement_time(Duration::new(measurement_time_s, 0))
        .sample_size(12)
        .configure_from_args()
}

criterion_group!(
    name = instance;
    config = make_config(8);
    targets = bench_instance
);
criterion_group!(
    name = cache;
    config = make_config(8);
    targets = bench_cache
);
// Combines loading module from cache, instantiating it and executing the instance.
// This is what every call in libwasmvm does.
criterion_group!(
    name = combined;
    config = make_config(5);
    targets = bench_combined
);
criterion_group!(
    name = multi_threaded_instance;
    config = Criterion::default()
        .without_plots()
        .measurement_time(Duration::new(16, 0))
        .sample_size(10)
        .configure_from_args();
    targets = bench_instance_threads
);
#[cfg(feature = "zk")]
criterion_group!(
    name = zk_circuit;
    config = Criterion::default()
        .without_plots()
        .measurement_time(Duration::new(12, 0))
        .sample_size(12)
        .configure_from_args();
    targets = bench_zk_circuit_cache
);

#[cfg(feature = "zk")]
criterion_main!(
    instance,
    cache,
    combined,
    multi_threaded_instance,
    zk_circuit
);
#[cfg(not(feature = "zk"))]
criterion_main!(instance, cache, combined, multi_threaded_instance);
