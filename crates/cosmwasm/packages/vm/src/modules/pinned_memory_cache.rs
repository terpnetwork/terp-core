use cosmwasm_std::Checksum;
use std::collections::{HashMap, VecDeque};

use super::cached_module::CachedModule;
#[cfg(feature = "zk")]
use crate::modules::{cached_module::CachedParam, CachedCircuit};
use crate::VmResult;

/// Struct storing some additional metadata, which is only of interest for the pinned cache,
/// alongside the cached module.
pub struct InstrumentedModule {
    /// Number of loads from memory this module received
    pub hits: u32,
    /// The actual cached module
    pub module: CachedModule,
}
/// Struct storing some additional metadata, which is only of interest for the pinned cache,
/// alongside the cached module.
#[cfg(feature = "zk")]
pub struct InstrumentedCircuit {
    /// Number of loads from memory this module received
    pub hits: u32,
    /// The actual cached module
    pub circuit: CachedCircuit,
}

#[cfg(feature = "zk")]
pub struct InstrumentedParam {
    /// Number of loads from memory this module received
    pub hits: u32,
    /// The actual cached module
    pub param: CachedParam,
}

/// Default maximum number of pinned ZK circuits before LRU eviction.
#[cfg(feature = "zk")]
const DEFAULT_MAX_PINNED_CIRCUITS: usize = 100;
/// Default maximum total bytes for pinned ZK circuits before LRU eviction.
#[cfg(feature = "zk")]
const DEFAULT_MAX_PINNED_CIRCUIT_SIZE_BYTES: usize = 100 * 1024 * 1024;

/// An pinned in memory module cache
pub struct PinnedMemoryCache {
    modules: HashMap<Checksum, InstrumentedModule>,
    #[cfg(feature = "zk")]
    circuits: HashMap<[u8; 72], InstrumentedCircuit>,
    #[cfg(feature = "zk")]
    params: HashMap<[u8; 36], InstrumentedParam>,
    #[cfg(feature = "zk")]
    max_circuit_count: Option<usize>,
    #[cfg(feature = "zk")]
    max_circuit_size_bytes: Option<usize>,
    #[cfg(feature = "zk")]
    circuit_pin_order: VecDeque<[u8; 72]>,
}

impl PinnedMemoryCache {
    /// Creates a new cache
    pub fn new() -> Self {
        PinnedMemoryCache {
            modules: HashMap::new(),
            #[cfg(feature = "zk")]
            circuits: HashMap::new(),
            #[cfg(feature = "zk")]
            params: HashMap::new(),
            #[cfg(feature = "zk")]
            max_circuit_count: Some(DEFAULT_MAX_PINNED_CIRCUITS),
            #[cfg(feature = "zk")]
            max_circuit_size_bytes: Some(DEFAULT_MAX_PINNED_CIRCUIT_SIZE_BYTES),
            #[cfg(feature = "zk")]
            circuit_pin_order: VecDeque::new(),
        }
    }

    pub fn iter(&self) -> impl Iterator<Item = (&Checksum, &InstrumentedModule)> {
        self.modules.iter()
    }
    pub fn iter_circuits(&self) -> impl Iterator<Item = (&[u8; 72], &InstrumentedCircuit)> {
        self.circuits.iter()
    }
    pub fn iter_params(&self) -> impl Iterator<Item = (&[u8; 36], &InstrumentedParam)> {
        self.params.iter()
    }

    pub fn store(&mut self, checksum: &Checksum, cached_module: CachedModule) -> VmResult<()> {
        self.modules.insert(
            *checksum,
            InstrumentedModule {
                hits: 0,
                module: cached_module,
            },
        );

        Ok(())
    }

    /// Removes a module from the cache
    /// Not found modules are silently ignored. Potential integrity errors (wrong checksum) are not checked / enforced
    pub fn remove(&mut self, checksum: &Checksum) -> VmResult<()> {
        self.modules.remove(checksum);
        Ok(())
    }

    /// Looks up a module in the cache and creates a new module
    pub fn load(&mut self, checksum: &Checksum) -> VmResult<Option<CachedModule>> {
        match self.modules.get_mut(checksum) {
            Some(cached) => {
                cached.hits = cached.hits.saturating_add(1);
                Ok(Some(cached.module.clone()))
            }
            None => Ok(None),
        }
    }

    /// Returns true if and only if this cache has an entry identified by the given checksum
    pub fn has(&self, checksum: &Checksum) -> bool {
        self.modules.contains_key(checksum)
    }

    /// Returns the number of elements in the cache.
    pub fn len(&self) -> usize {
        let mut l = self.modules.len();
        #[cfg(feature = "zk")]
        {
            l += self.circuits.len();
        }
        l
    }
    /// Returns cumulative size of all elements in the cache.
    ///
    /// This is based on the values provided with `store`. No actual
    /// memory size is measured here.
    pub fn size(&self) -> usize {
        // Sum module sizes: key (address) + module size estimate
        let module_size: usize = self
            .iter()
            .map(|(key, module)| std::mem::size_of_val(key) + module.module.size_estimate)
            .sum();

        // Sum circuit sizes: key (address) + circuit actual size
        #[cfg(feature = "zk")]
        {
            let circuit_size: usize = self
                .iter_circuits()
                .map(|(key, zk)| std::mem::size_of_val(key) + zk.circuit.size_estimate)
                .sum();

            module_size + circuit_size
        }
        #[cfg(not(feature = "zk"))]
        module_size
    }
}

#[cfg(feature = "zk")]
impl PinnedMemoryCache {
    /// Returns true if and only if this cache has an entry identified by the given checksum
    pub fn has_circuit(&self, circuit_file_key: &[u8; 72]) -> bool {
        return self.circuits.contains_key(circuit_file_key);
    }
    pub fn store_circuit(
        &mut self,
        circuit_checksum_key: &[u8; 72],
        cached_circuit: CachedCircuit,
    ) -> VmResult<()> {
        println!("storing to pinned_memory_cache;");
        let is_update = self.circuits.contains_key(circuit_checksum_key);
        if !is_update {
            self.evict_circuits_for_insert(cached_circuit.size_estimate)?;
        } else {
            self.circuit_pin_order.retain(|k| k != circuit_checksum_key);
        }
        self.circuit_pin_order.push_back(*circuit_checksum_key);
        self.circuits.insert(
            *circuit_checksum_key,
            InstrumentedCircuit {
                hits: 0,
                circuit: cached_circuit,
            },
        );
        Ok(())
    }

    fn evict_circuits_for_insert(&mut self, incoming_size: usize) -> VmResult<()> {
        loop {
            let over_count = self
                .max_circuit_count
                .is_some_and(|max| self.circuits.len() >= max);
            let current_size: usize = self
                .iter_circuits()
                .map(|(_, c)| c.circuit.size_estimate)
                .sum();
            let over_size = self.max_circuit_size_bytes.is_some_and(|max| {
                !self.circuits.is_empty() && current_size.saturating_add(incoming_size) > max
            });
            if !over_count && !over_size {
                break;
            }
            let Some(oldest) = self.circuit_pin_order.pop_front() else {
                break;
            };
            self.circuits.remove(&oldest);
        }
        Ok(())
    }
    pub fn store_param(
        &mut self,
        param_file_key: &[u8; 36],
        cached_param: CachedParam,
    ) -> VmResult<()> {
        println!("storing param to pinned_memory_cache;");
        self.params.insert(
            *param_file_key,
            InstrumentedParam {
                hits: 0,
                param: cached_param,
            },
        );
        Ok(())
    }

    pub fn remove_circuit(&mut self, checksum: &[u8; 72]) -> VmResult<()> {
        self.circuits.remove(checksum);
        self.circuit_pin_order.retain(|k| k != checksum);
        Ok(())
    }

    pub fn remove_param(&mut self, param_file_key: &[u8; 36]) -> VmResult<()> {
        self.params.remove(param_file_key);
        Ok(())
    }

    /// Looks up a module in the cache and creates a new module.
    /// IMPORTANT: pinned memory lookup is not checksum of vk file, but checksum of loaded vk with cs & params (since params and vk are different)
    pub fn load_circuit(&mut self, circuit_file_key: &[u8; 72]) -> VmResult<Option<CachedCircuit>> {
        match self.circuits.get_mut(circuit_file_key) {
            Some(cached) => {
                cached.hits = cached.hits.saturating_add(1);
                Ok(Some(cached.circuit.clone()))
            }
            None => Ok(None),
        }
    }

    /// Load raw param bytes by 36-byte param file key.
    pub fn load_param(&mut self, param_file_key: &[u8; 36]) -> VmResult<Option<CachedParam>> {
        match self.params.get_mut(param_file_key) {
            Some(cached) => {
                cached.hits = cached.hits.saturating_add(1);
                Ok(Some(cached.param.clone()))
            }
            None => Ok(None),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        wasm_backend::{compile, make_compiling_engine, make_runtime_engine},
        Size,
    };
    use wasmer::{imports, Instance as WasmerInstance, Store};
    use wasmer_middlewares::metering::set_remaining_points;

    static NORICK_CIRCUIT: &[u8] = include_bytes!("../../testdata/norick_vk.bin");
    const TESTING_MEMORY_LIMIT: Option<Size> = Some(Size::mebi(16));
    const TESTING_GAS_LIMIT: u64 = 500_000;

    #[test]
    fn pinned_memory_cache_run() {
        let mut cache = PinnedMemoryCache::new();

        // Create module
        let wasm = wat::parse_str(
            r#"(module
            (type $t0 (func (param i32) (result i32)))
            (func $add_one (export "add_one") (type $t0) (param $p0 i32) (result i32)
                local.get $p0
                i32.const 1
                i32.add)
            )"#,
        )
        .unwrap();
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
            size_estimate: 0,
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
    fn has_works() {
        let mut cache = PinnedMemoryCache::new();

        // Create module
        let wasm = wat::parse_str(
            r#"(module
            (type $t0 (func (param i32) (result i32)))
            (func $add_one (export "add_one") (type $t0) (param $p0 i32) (result i32)
                local.get $p0
                i32.const 1
                i32.add)
            )"#,
        )
        .unwrap();
        let checksum = Checksum::generate(&wasm);

        assert!(!cache.has(&checksum));

        // Add
        let engine = make_compiling_engine(TESTING_MEMORY_LIMIT, None);
        let original = compile(&engine, &wasm).unwrap();
        let module = CachedModule {
            module: original,
            engine: make_runtime_engine(TESTING_MEMORY_LIMIT),
            size_estimate: 0,
        };
        cache.store(&checksum, module).unwrap();

        assert!(cache.has(&checksum));

        // Remove
        cache.remove(&checksum).unwrap();

        assert!(!cache.has(&checksum));

        #[cfg(feature = "zk")]
        {
            use crate::COSMWASM_FOOTER_LENGTH;
            use zk_cosmwasm::CircuitFooter;

            let zk = NORICK_CIRCUIT;

            let footer =
                CircuitFooter::from_bytes(&zk[zk.len() - COSMWASM_FOOTER_LENGTH..]).unwrap();

            assert!(!cache.has_circuit(&footer.to_circuit_key()));

            let circuit = CachedCircuit {
                vk: zk_cosmwasm::AnyVerifyingKey::try_from(zk).unwrap(),
                size_estimate: zk.len(),
            };
            cache
                .store_circuit(&footer.to_circuit_key(), circuit)
                .unwrap();
            assert!(cache.has_circuit(&footer.to_circuit_key()));
            // Remove
            cache.remove_circuit(&footer.to_circuit_key()).unwrap();
            assert!(!cache.has(&checksum));
        }
    }

    #[test]
    fn hit_metric_works() {
        let mut cache = PinnedMemoryCache::new();

        // Create module
        let wasm = wat::parse_str(
            r#"(module
            (type $t0 (func (param i32) (result i32)))
            (func $add_one (export "add_one") (type $t0) (param $p0 i32) (result i32)
                local.get $p0
                i32.const 1
                i32.add)
            )"#,
        )
        .unwrap();
        let checksum = Checksum::generate(&wasm);

        assert!(!cache.has(&checksum));

        // Add
        let engine = make_compiling_engine(TESTING_MEMORY_LIMIT, None);
        let original = compile(&engine, &wasm).unwrap();
        let module = CachedModule {
            module: original,
            engine: make_runtime_engine(TESTING_MEMORY_LIMIT),
            size_estimate: 0,
        };
        cache.store(&checksum, module).unwrap();

        let (_checksum, module) = cache
            .iter()
            .find(|(iter_checksum, _module)| **iter_checksum == checksum)
            .unwrap();

        assert_eq!(module.hits, 0);

        let _ = cache.load(&checksum).unwrap();
        let (_checksum, module) = cache
            .iter()
            .find(|(iter_checksum, _module)| **iter_checksum == checksum)
            .unwrap();

        assert_eq!(module.hits, 1);

        #[cfg(feature = "zk")]
        {
            let zk = NORICK_CIRCUIT;
            let footer = zk_cosmwasm::CircuitFooter::from_bytes(
                &zk[zk.len() - crate::COSMWASM_FOOTER_LENGTH..],
            )
            .unwrap();
            assert!(!cache.has_circuit(&footer.to_circuit_key()));

            let circuit = CachedCircuit {
                vk: zk_cosmwasm::AnyVerifyingKey::try_from(zk).unwrap(),
                size_estimate: zk.len(),
            };
            cache
                .store_circuit(&footer.to_circuit_key(), circuit)
                .unwrap();

            let (_checksum, circuit) = cache
                .iter_circuits()
                .find(|(iter_checksum, _circuit)| **iter_checksum == footer.to_circuit_key())
                .unwrap();

            assert_eq!(circuit.hits, 0);

            let _ = cache.load_circuit(&footer.to_circuit_key()).unwrap();
            let (_checksum, circuit) = cache
                .iter_circuits()
                .find(|(iter_checksum, _circuit)| **iter_checksum == footer.to_circuit_key())
                .unwrap();

            assert_eq!(circuit.hits, 1);
        }
    }

    #[test]
    fn len_works() {
        let mut cache = PinnedMemoryCache::new();

        // Create module
        let wasm = wat::parse_str(
            r#"(module
            (type $t0 (func (param i32) (result i32)))
            (func $add_one (export "add_one") (type $t0) (param $p0 i32) (result i32)
                local.get $p0
                i32.const 1
                i32.add)
            )"#,
        )
        .unwrap();
        let checksum = Checksum::generate(&wasm);

        assert_eq!(cache.len(), 0);

        // Add
        let engine = make_compiling_engine(TESTING_MEMORY_LIMIT, None);
        let original = compile(&engine, &wasm).unwrap();
        let module = CachedModule {
            module: original,
            engine: make_runtime_engine(TESTING_MEMORY_LIMIT),
            size_estimate: 0,
        };
        cache.store(&checksum, module).unwrap();

        assert_eq!(cache.len(), 1);

        // Remove
        cache.remove(&checksum).unwrap();

        assert_eq!(cache.len(), 0);

        #[cfg(feature = "zk")]
        {
            let zk = NORICK_CIRCUIT;

            let footer = zk_cosmwasm::CircuitFooter::from_bytes(
                &zk[zk.len() - crate::COSMWASM_FOOTER_LENGTH..],
            )
            .unwrap();

            assert_eq!(cache.len(), 0);

            let circuit = CachedCircuit {
                vk: zk_cosmwasm::AnyVerifyingKey::try_from(zk).unwrap(),
                size_estimate: zk.len(),
            };

            cache
                .store_circuit(&footer.to_circuit_key(), circuit)
                .unwrap();

            assert_eq!(cache.len(), 1);

            // Remove
            cache.remove_circuit(&footer.to_circuit_key()).unwrap();

            assert_eq!(cache.len(), 0);
        }
    }

    #[test]
    fn size_works() {
        let mut cache = PinnedMemoryCache::new();

        // Create module
        let wasm1 = wat::parse_str(
            r#"(module
            (type $t0 (func (param i32) (result i32)))
            (func $add_one (export "add_one") (type $t0) (param $p0 i32) (result i32)
                local.get $p0
                i32.const 1
                i32.add)
            )"#,
        )
        .unwrap();
        let checksum1 = Checksum::generate(&wasm1);
        let wasm2 = wat::parse_str(
            r#"(module
            (type $t0 (func (param i32) (result i32)))
            (func $add_one (export "add_two") (type $t0) (param $p0 i32) (result i32)
                local.get $p0
                i32.const 2
                i32.add)
            )"#,
        )
        .unwrap();
        let checksum2 = Checksum::generate(&wasm2);

        assert_eq!(cache.size(), 0);

        // Add 1
        let engine1 = make_compiling_engine(TESTING_MEMORY_LIMIT, None);
        let module = CachedModule {
            module: compile(&engine1, &wasm1).unwrap(),
            engine: make_runtime_engine(TESTING_MEMORY_LIMIT),
            size_estimate: 500,
        };
        cache.store(&checksum1, module).unwrap();
        assert_eq!(cache.size(), 532);

        // Add 2
        let engine2 = make_compiling_engine(TESTING_MEMORY_LIMIT, None);
        let module = CachedModule {
            module: compile(&engine2, &wasm2).unwrap(),
            engine: make_runtime_engine(TESTING_MEMORY_LIMIT),
            size_estimate: 300,
        };
        cache.store(&checksum2, module.clone()).unwrap();
        assert_eq!(cache.size(), 532 + 332);

        // Remove 1
        cache.remove(&checksum1).unwrap();
        assert_eq!(cache.size(), 332);

        // Remove 2
        cache.remove(&checksum2).unwrap();
        assert_eq!(cache.size(), 0);

        #[cfg(feature = "zk")]
        {
            let zk = NORICK_CIRCUIT;

            let footer = zk_cosmwasm::CircuitFooter::from_bytes(
                &zk[zk.len() - crate::COSMWASM_FOOTER_LENGTH..],
            )
            .unwrap();

            assert_eq!(cache.size(), 0);
            // Add 1: 66135
            let circuit = CachedCircuit {
                vk: zk_cosmwasm::AnyVerifyingKey::try_from(zk).unwrap(),
                size_estimate: zk.len(),
            };
            assert_eq!(zk.len(), circuit.vk.to_bytes_with_params().unwrap().len());

            cache
                .store_circuit(&footer.to_circuit_key(), circuit)
                .unwrap();
            assert_eq!(cache.size(), zk.len() + std::mem::size_of::<[u8; 72]>());

            // Add 2
            cache.store(&checksum1, module).unwrap();
            assert_eq!(
                cache.size(),
                332 + zk.len() + std::mem::size_of::<[u8; 72]>()
            );

            // Remove 1
            cache.remove_circuit(&footer.to_circuit_key()).unwrap();
            assert_eq!(cache.size(), 332);

            // Remove 2
            cache.remove(&checksum1).unwrap();
            assert_eq!(cache.size(), 0);
        }
    }
}
