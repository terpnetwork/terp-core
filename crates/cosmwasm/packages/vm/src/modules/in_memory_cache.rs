use clru::{CLruCache, CLruCacheConfig, WeightScale};
use std::collections::hash_map::RandomState;
use std::num::NonZeroUsize;
// TODO: implement clru cache for circutis so that we reuse existing cache instead of doubling it (tldr: do not over allocate memory )
use cosmwasm_std::Checksum;

use super::cached_module::CachedModule;
use crate::{cache::CacheKey, modules::cached_module::CacheEntry, Size, VmError, VmResult};

// Minimum module size.
// Based on `examples/module_size.sh`, and the cosmwasm-plus contracts.
// We use an estimated *minimum* module size in order to compute a number of pre-allocated entries
// that are enough to handle a size-limited cache without requiring re-allocation / resizing.
// This will incur an extra memory cost for the unused entries, but it's negligible:
// Assuming the cost per entry is 48 bytes, 10000 entries will have an extra cost of just ~500 kB.
// Which is a very small percentage (~0.03%) of our typical cache memory budget (2 GB).
const MINIMUM_MODULE_SIZE: Size = Size::kibi(250);

#[derive(Debug)]
struct SizeScale;

// Single implementation covering both types via the enum
impl WeightScale<CacheKey, CacheEntry> for SizeScale {
    #[inline]
    fn weight(&self, key: &CacheKey, value: &CacheEntry) -> usize {
        let val_size = match value {
            CacheEntry::Module(m) => m.size_estimate,
            CacheEntry::Circuit(c) => c.size_estimate,
            CacheEntry::Param(p) => p.size_estimate,
        };
        std::mem::size_of_val(key) + val_size
    }
}

/// An in-memory cache with a strict, unified memory limit
pub struct InMemoryCache {
    /// A single LRU cache holding both modules and circuits.
    /// This guarantees the total memory used never exceeds the configured `Size`.
    cache: Option<CLruCache<CacheKey, CacheEntry, RandomState, SizeScale>>,
}

#[cfg(feature = "zk")]
impl InMemoryCache {
    pub fn store_circuit(
        &mut self,
        circuit_file_key: &[u8; 72],
        cached_zk: &super::CachedCircuit,
    ) -> VmResult<()> {
        if let Some(zk) = &mut self.cache {
            use crate::cache::CacheKey;

            zk.put_with_weight(
                CacheKey::CircuitKey(*circuit_file_key),
                CacheEntry::Circuit(cached_zk.clone()),
            )
            .map_err(|e| VmError::cache_err(format!("{e:?}")))?;
        }
        Ok(())
    }
    /// Looks up a module in the cache and creates a new module
    pub fn load_circuit(
        &mut self,
        circuit_file_key: &[u8; 72],
    ) -> VmResult<Option<super::CachedCircuit>> {
        println!("loading circuit from in_memory_cache;");
        if let Some(modules) = &mut self.cache {
            println!("in_memory_cache exists;");
            match modules.get(&CacheKey::CircuitKey(*circuit_file_key)) {
                Some(cached) => match cached {
                    CacheEntry::Circuit(zk) => Ok(Some(zk.clone())),
                    _ => Ok(None),
                },
                None => Ok(None),
            }
        } else {
            println!("no in_memory_cache;");
            Ok(None)
        }
    }
    pub fn store_param(
        &mut self,
        param_file_key: &[u8; 36],
        cached_param: &super::CachedParam,
    ) -> VmResult<()> {
        if let Some(cache) = &mut self.cache {
            cache
                .put_with_weight(
                    CacheKey::PartialKey(*param_file_key),
                    CacheEntry::Param(cached_param.clone()),
                )
                .map_err(|e| VmError::cache_err(format!("{e:?}")))?;
        }
        Ok(())
    }

    /// Looks up raw param bytes in the unified LRU cache.
    pub fn load_param(
        &mut self,
        param_file_key: &[u8; 36],
    ) -> VmResult<Option<super::CachedParam>> {
        if let Some(modules) = &mut self.cache {
            match modules.get(&CacheKey::PartialKey(*param_file_key)) {
                Some(cached) => match cached {
                    CacheEntry::Param(p) => Ok(Some(p.clone())),
                    _ => Ok(None),
                },
                None => Ok(None),
            }
        } else {
            Ok(None)
        }
    }

    /// Looks up a circuit stored under a 36-byte vk file key.
    ///
    /// Note: full circuits are normally keyed by the 72-byte circuit key via
    /// [`Self::load_circuit`]. This exists for partial-key lookups of cs+vk
    /// material that was cached under `CacheKey::PartialKey`.
    pub fn load_vk(&mut self, vk_file_key: &[u8; 36]) -> VmResult<Option<super::CachedCircuit>> {
        if let Some(modules) = &mut self.cache {
            match modules.get(&CacheKey::PartialKey(*vk_file_key)) {
                Some(cached) => match cached {
                    CacheEntry::Circuit(zk) => Ok(Some(zk.clone())),
                    _ => Ok(None),
                },
                None => Ok(None),
            }
        } else {
            Ok(None)
        }
    }
}

impl InMemoryCache {
    /// Creates a new cache with the given size (in bytes)
    pub fn new(size: Size) -> Self {
        let preallocated_entries = size.0 / MINIMUM_MODULE_SIZE.0;
        let size = NonZeroUsize::new(size.0);

        InMemoryCache {
            cache: size.map(|non_zero_size| {
                CLruCache::with_config(
                    CLruCacheConfig::new(non_zero_size)
                        .with_memory(preallocated_entries)
                        .with_scale(SizeScale),
                )
            }),
        }
    }

    pub fn store(&mut self, checksum: &Checksum, cached_module: CachedModule) -> VmResult<()> {
        if let Some(modules) = &mut self.cache {
            modules
                .put_with_weight(
                    CacheKey::Checksum(*checksum),
                    CacheEntry::Module(cached_module),
                )
                .map_err(|e| VmError::cache_err(format!("{e:?}")))?;
        }
        Ok(())
    }

    /// Looks up a module in the cache and creates a new module
    pub fn load(&mut self, checksum: &Checksum) -> VmResult<Option<CachedModule>> {
        if let Some(modules) = &mut self.cache {
            match modules.get(&CacheKey::Checksum(*checksum)) {
                Some(cached) => match cached {
                    CacheEntry::Module(cached) => Ok(Some(cached.clone())),
                    _ => Ok(None),
                },
                None => Ok(None),
            }
        } else {
            Ok(None)
        }
    }

    /// Returns the number of elements in the cache.
    pub fn len(&self) -> usize {
        self.cache
            .as_ref()
            .map(|cache| cache.len())
            .unwrap_or_default()
    }

    /// Returns cumulative size of all elements in the cache.
    ///
    /// This is based on the values provided with `store`. No actual
    /// memory size is measured here.
    pub fn size(&self) -> usize {
        self.cache
            .as_ref()
            .map(|cache| cache.weight())
            .unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wasm_backend::{compile, make_compiling_engine, make_runtime_engine};
    use std::mem;
    use wasmer::{imports, Instance as WasmerInstance, Module, Store};
    use wasmer_middlewares::metering::set_remaining_points;

    const TESTING_MEMORY_LIMIT: Option<Size> = Some(Size::mebi(16));
    const TESTING_GAS_LIMIT: u64 = 500_000;
    // Based on `examples/module_size.sh`
    const TESTING_WASM_SIZE_FACTOR: usize = 18;

    const WAT1: &str = r#"(module
        (type $t0 (func (param i32) (result i32)))
        (func $add_one (export "add_one") (type $t0) (param $p0 i32) (result i32)
            local.get $p0
            i32.const 1
            i32.add)
        )"#;
    const WAT2: &str = r#"(module
        (type $t0 (func (param i32) (result i32)))
        (func $add_one (export "add_two") (type $t0) (param $p0 i32) (result i32)
            local.get $p0
            i32.const 2
            i32.add)
        )"#;
    const WAT3: &str = r#"(module
        (type $t0 (func (param i32) (result i32)))
        (func $add_one (export "add_three") (type $t0) (param $p0 i32) (result i32)
            local.get $p0
            i32.const 3
            i32.add)
        )"#;

    #[test]
    fn check_element_sizes() {
        let key_size = mem::size_of::<Checksum>();
        assert_eq!(key_size, 32);

        let value_size = mem::size_of::<Module>();
        assert_eq!(value_size, 8);

        // Just in case we want to go that route
        let boxed_value_size = mem::size_of::<Box<Module>>();
        assert_eq!(boxed_value_size, 8);
    }

    #[test]
    fn in_memory_cache_run() {
        let mut cache = InMemoryCache::new(Size::mebi(200));

        // Create module
        let wasm = wat::parse_str(WAT1).unwrap();
        let checksum = Checksum::generate(&wasm);

        // Module does not exist
        let cache_entry = cache.load(&checksum).unwrap();
        assert!(cache_entry.is_none());

        // Compile module
        let engine = make_compiling_engine(TESTING_MEMORY_LIMIT, None);
        let original = compile(&engine, &wasm).unwrap();

        // Ensure original module can be executed
        {
            let mut store = Store::new(engine.clone());
            let instance = WasmerInstance::new(&mut store, &original, &imports! {}).unwrap();
            set_remaining_points(&mut store, &instance, TESTING_GAS_LIMIT);
            let add_one = instance.exports.get_function("add_one").unwrap();
            let result = add_one.call(&mut store, &[42.into()]).unwrap();
            assert_eq!(result[0].unwrap_i32(), 43);
        }

        // Store module
        let module = CachedModule {
            module: original,
            engine: make_runtime_engine(TESTING_MEMORY_LIMIT),
            size_estimate: wasm.len() * TESTING_WASM_SIZE_FACTOR,
        };
        cache.store(&checksum, module).unwrap();

        // Load module
        let cached = cache.load(&checksum).unwrap().unwrap();

        // Ensure cached module can be executed
        {
            let mut store = Store::new(engine);
            let instance = WasmerInstance::new(&mut store, &cached.module, &imports! {}).unwrap();
            set_remaining_points(&mut store, &instance, TESTING_GAS_LIMIT);
            let add_one = instance.exports.get_function("add_one").unwrap();
            let result = add_one.call(&mut store, &[42.into()]).unwrap();
            assert_eq!(result[0].unwrap_i32(), 43);
        }
    }

    #[test]
    fn len_works() {
        let mut cache = InMemoryCache::new(Size::mebi(2));

        // Create module
        let wasm1 = wat::parse_str(WAT1).unwrap();
        let checksum1 = Checksum::generate(&wasm1);
        let wasm2 = wat::parse_str(WAT2).unwrap();
        let checksum2 = Checksum::generate(&wasm2);
        let wasm3 = wat::parse_str(WAT3).unwrap();
        let checksum3 = Checksum::generate(&wasm3);

        assert_eq!(cache.len(), 0);

        // Add 1
        let engine1 = make_compiling_engine(TESTING_MEMORY_LIMIT, None);
        let module = CachedModule {
            module: compile(&engine1, &wasm1).unwrap(),
            engine: make_runtime_engine(TESTING_MEMORY_LIMIT),
            size_estimate: 900_000,
        };
        cache.store(&checksum1, module).unwrap();
        assert_eq!(cache.len(), 1);

        // Add 2
        let engine2 = make_compiling_engine(TESTING_MEMORY_LIMIT, None);
        let module = CachedModule {
            module: compile(&engine2, &wasm2).unwrap(),
            engine: make_runtime_engine(TESTING_MEMORY_LIMIT),
            size_estimate: 900_000,
        };
        cache.store(&checksum2, module).unwrap();
        assert_eq!(cache.len(), 2);

        // Add 3 (pushes out the previous two)
        let engine3 = make_compiling_engine(TESTING_MEMORY_LIMIT, None);
        let module = CachedModule {
            module: compile(&engine3, &wasm3).unwrap(),
            engine: make_runtime_engine(TESTING_MEMORY_LIMIT),
            size_estimate: 1_500_000,
        };
        cache.store(&checksum3, module).unwrap();
        assert_eq!(cache.len(), 1);
    }

    #[test]
    fn size_works() {
        let mut cache = InMemoryCache::new(Size::mebi(2));

        // Create module
        let wasm1 = wat::parse_str(WAT1).unwrap();
        let checksum1 = Checksum::generate(&wasm1);
        let wasm2 = wat::parse_str(WAT2).unwrap();
        let checksum2 = Checksum::generate(&wasm2);
        let wasm3 = wat::parse_str(WAT3).unwrap();
        let checksum3 = Checksum::generate(&wasm3);

        assert_eq!(cache.size(), 0);

        // Add 1
        let engine1 = make_compiling_engine(TESTING_MEMORY_LIMIT, None);
        let module = CachedModule {
            module: compile(&engine1, &wasm1).unwrap(),
            engine: make_runtime_engine(TESTING_MEMORY_LIMIT),
            size_estimate: 900_000,
        };
        cache.store(&checksum1, module).unwrap();
        assert_eq!(cache.size(), 900_000 + std::mem::size_of::<CacheKey>());

        // Add 2
        let engine2 = make_compiling_engine(TESTING_MEMORY_LIMIT, None);
        let module = CachedModule {
            module: compile(&engine2, &wasm2).unwrap(),
            engine: make_runtime_engine(TESTING_MEMORY_LIMIT),
            size_estimate: 800_000,
        };
        cache.store(&checksum2, module).unwrap();
        assert_eq!(
            cache.size(),
            900_000 + 800_000 + 2 * std::mem::size_of::<CacheKey>()
        );

        // Add 3 (pushes out the previous two)
        let engine3 = make_compiling_engine(TESTING_MEMORY_LIMIT, None);
        let module = CachedModule {
            module: compile(&engine3, &wasm3).unwrap(),
            engine: make_runtime_engine(TESTING_MEMORY_LIMIT),
            size_estimate: 1_500_000,
        };
        cache.store(&checksum3, module).unwrap();
        assert_eq!(cache.size(), 1_500_000 + std::mem::size_of::<CacheKey>());
    }

    #[test]
    fn in_memory_cache_works_for_zero_size() {
        // A cache size of 0 practically disabled the cache. It must work
        // like any cache with insufficient space.
        // We test all common methods here.

        let mut cache = InMemoryCache::new(Size::mebi(0));

        // Create module
        let wasm = wat::parse_str(WAT1).unwrap();
        let checksum = Checksum::generate(&wasm);

        // Module does not exist
        let cache_entry = cache.load(&checksum).unwrap();
        assert!(cache_entry.is_none());
        assert_eq!(cache.len(), 0);
        assert_eq!(cache.size(), 0);

        // Compile module
        let engine = make_compiling_engine(TESTING_MEMORY_LIMIT, None);
        let original = compile(&engine, &wasm).unwrap();

        // Store module
        let module = CachedModule {
            module: original,
            engine: make_runtime_engine(TESTING_MEMORY_LIMIT),
            size_estimate: wasm.len() * TESTING_WASM_SIZE_FACTOR,
        };
        cache.store(&checksum, module).unwrap();
        assert_eq!(cache.len(), 0);
        assert_eq!(cache.size(), 0);

        // Load module
        let cached = cache.load(&checksum).unwrap();
        assert!(cached.is_none());
        assert_eq!(cache.len(), 0);
        assert_eq!(cache.size(), 0);
    }
}
