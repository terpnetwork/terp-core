#[cfg(feature = "zk")]
use crate::{check_circuit, SerializedCircuitData};
use cosmwasm_std::Checksum;
#[cfg(feature = "zk")]
use crate::COSMWASM_FOOTER_LENGTH;
use std::collections::{BTreeSet, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::marker::PhantomData;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::{Arc, Mutex};
use wasmer::{Module, Store};
#[cfg(feature = "zk")]
use zk_cosmwasm::{CircuitFooter, ZkError};

use crate::backend::{Backend, BackendApi, Querier, Storage};
use crate::capabilities::required_capabilities_from_module;
use crate::compatibility::check_wasm;
use crate::config::{CacheOptions, Config, WasmLimits};
use crate::errors::{VmError, VmResult};
use crate::filesystem::mkdir_p;
use crate::instance::{Instance, InstanceOptions};
use crate::modules::{
    CachedCircuit, CachedModule, FileSystemCache, InMemoryCache, PinnedMemoryCache,
};
use crate::parsed_wasm::ParsedWasm;
use crate::size::Size;
use crate::static_analysis::{Entrypoint, ExportInfo, REQUIRED_IBC_EXPORTS};
use crate::wasm_backend::{compile, compile_module, make_compiling_engine};

const STATE_DIR: &str = "state";
// Things related to the state of the blockchain.
const WASM_DIR: &str = "wasm";
const ZK_PARAM_DIR: &str = "zk_param";
const ZK_VK_DIR: &str = "zk_vk";
const ZK_CIRCUIT_DIR: &str = "zk_circuit";

const CACHE_DIR: &str = "cache";
// Cacheable things.
const MODULES_DIR: &str = "modules";

#[derive(Eq, Hash, PartialEq, Debug, Clone)]
pub enum CacheKey {
    Checksum(Checksum),
    PartialKey([u8; 36]),
    CircuitKey([u8; 72]),
}

impl serde::Serialize for CacheKey {
    fn serialize<S>(&self, s: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        match self {
            CacheKey::Checksum(checksum) => checksum.serialize(s),
            CacheKey::PartialKey(pk36) => s.serialize_bytes(pk36.as_slice()),
            CacheKey::CircuitKey(ck72) => s.serialize_bytes(ck72.as_slice()),
        }
    }
}
/// Statistics about the usage of a cache instance. Those values are node
/// specific and must not be used in a consensus critical context.
/// When a node is hit by a client for simulations or other queries, hits and misses
/// increase. Also a node restart will reset the values.
///
/// All values should be increment using saturated addition to ensure the node does not
/// crash in case the stats exceed the integer limit.
#[derive(Debug, Default, Clone, Copy)]
pub struct Stats {
    pub hits_pinned_memory_cache: u32,
    pub hits_memory_cache: u32,
    pub hits_fs_cache: u32,
    pub misses: u32,
}

#[derive(Debug, Clone, Copy)]
pub struct Metrics {
    pub stats: Stats,
    pub elements_pinned_memory_cache: usize,
    pub elements_memory_cache: usize,
    pub size_pinned_memory_cache: usize,
    pub size_memory_cache: usize,
}

#[derive(Debug, Clone)]
pub struct PerModuleMetrics {
    /// Hits (i.e. loads) of the module from the cache
    pub hits: u32,
    /// Size the module takes up in memory
    pub size: usize,
}

#[derive(Debug, Clone)]
pub struct PinnedMetrics {
    // It is *intentional* that this is only a vector
    // We don't need a potentially expensive hashing algorithm here
    // The checksums are sourced from a hashmap already, ensuring uniqueness of the checksums
    pub per_module: Vec<(CacheKey, PerModuleMetrics)>,
}

pub struct CacheInner {
    /// The directory in which the Wasm blobs are stored in the file system.
    wasm_path: PathBuf,
    pinned_memory_cache: PinnedMemoryCache,
    memory_cache: InMemoryCache,
    fs_cache: FileSystemCache,
    stats: Stats,
}

#[cfg(feature = "zk")]
impl CacheInner {
    pub fn param_path(&self) -> PathBuf {
        self.wasm_path.join(ZK_PARAM_DIR)
    }
    pub fn vk_path(&self) -> PathBuf {
        self.wasm_path.join(ZK_VK_DIR)
    }
    pub fn circuit_path(&self) -> PathBuf {
        self.wasm_path.join(ZK_CIRCUIT_DIR)
    }
}

pub struct Cache<A: BackendApi, S: Storage, Q: Querier> {
    /// Available capabilities are immutable for the lifetime of the cache,
    /// i.e. any number of read-only references is allowed to access it concurrently.
    available_capabilities: HashSet<String>,
    /// Shared so `circuit_loader` closures can outlive a single `get_instance` call.
    inner: Arc<Mutex<CacheInner>>,
    instance_memory_limit: Size,
    // Those two don't store data but only fix type information
    type_api: PhantomData<A>,
    type_storage: PhantomData<S>,
    type_querier: PhantomData<Q>,
    /// To prevent concurrent access to `WasmerInstance::new`
    instantiation_lock: Mutex<()>,
    wasm_limits: WasmLimits,
}

#[derive(PartialEq, Eq, Debug)]
#[non_exhaustive]
pub struct AnalysisReport {
    /// `true` if and only if all [`REQUIRED_IBC_EXPORTS`] exist as exported functions.
    /// This does not guarantee they are functional or even have the correct signatures.
    pub has_ibc_entry_points: bool,
    /// A set of all entrypoints that are exported by the contract.
    pub entrypoints: BTreeSet<Entrypoint>,
    /// The set of capabilities the contract requires.
    pub required_capabilities: BTreeSet<String>,
    /// The contract migrate version exported set by the contract developer
    pub contract_migrate_version: Option<u64>,
}

impl<A, S, Q> Cache<A, S, Q>
where
    A: BackendApi + 'static, // 'static is needed by `impl<…> Instance`
    S: Storage + 'static,    // 'static is needed by `impl<…> Instance`
    Q: Querier + 'static,    // 'static is needed by `impl<…> Instance`
{
    /// Creates a new cache that stores data in `base_dir`.
    ///
    /// # Safety
    ///
    /// This function is marked unsafe due to `FileSystemCache::new`, which implicitly
    /// assumes the disk contents are correct, and there's no way to ensure the artifacts
    /// stored in the cache haven't been corrupted or tampered with.
    pub unsafe fn new(options: CacheOptions) -> VmResult<Self> {
        Self::new_with_config(Config {
            wasm_limits: WasmLimits::default(),
            cache: options,
        })
    }

    /// Creates a new cache with the given configuration.
    /// This allows configuring lots of limits and sizes.
    ///
    /// # Safety
    ///
    /// This function is marked unsafe due to `FileSystemCache::new`, which implicitly
    /// assumes the disk contents are correct, and there's no way to ensure the artifacts
    /// stored in the cache haven't been corrupted or tampered with.
    pub unsafe fn new_with_config(config: Config) -> VmResult<Self> {
        let Config {
            cache:
                CacheOptions {
                    base_dir,
                    available_capabilities,
                    memory_cache_size_bytes,
                    instance_memory_limit_bytes,
                },
            wasm_limits,
        } = config;

        let state_path = base_dir.join(STATE_DIR);
        let cache_path = base_dir.join(CACHE_DIR);

        let wasm_path = state_path.join(WASM_DIR);
        let zk_param_path = wasm_path.join(ZK_PARAM_DIR);
        let zk_vk_path = wasm_path.join(ZK_VK_DIR);
        let zk_zk_path = wasm_path.join(ZK_CIRCUIT_DIR);

        // Ensure all the needed directories exist on disk.
        mkdir_p(&state_path).map_err(|_e| VmError::cache_err("Error creating state directory"))?;
        mkdir_p(&cache_path).map_err(|_e| VmError::cache_err("Error creating cache directory"))?;
        mkdir_p(&wasm_path).map_err(|_e| VmError::cache_err("Error creating wasm directory"))?;
        mkdir_p(&zk_param_path).map_err(|_e| VmError::cache_err("Error creating zk_param dir"))?;
        mkdir_p(&zk_vk_path).map_err(|_e| VmError::cache_err("Error creating zk_param dir"))?;
        mkdir_p(&zk_zk_path).map_err(|_e| VmError::cache_err("Error creating zk_param dir"))?;

        let fs_cache = FileSystemCache::new(cache_path.join(MODULES_DIR), false)
            .map_err(|e| VmError::cache_err(format!("Error file system cache: {e}")))?;
        Ok(Cache {
            available_capabilities,
            inner: Arc::new(Mutex::new(CacheInner {
                wasm_path,
                pinned_memory_cache: PinnedMemoryCache::new(),
                memory_cache: InMemoryCache::new(memory_cache_size_bytes),
                fs_cache,
                stats: Stats::default(),
            })),
            instance_memory_limit: instance_memory_limit_bytes,
            type_storage: PhantomData::<S>,
            type_api: PhantomData::<A>,
            type_querier: PhantomData::<Q>,
            instantiation_lock: Mutex::new(()),
            wasm_limits,
        })
    }

    /// If `unchecked` is true, the filesystem cache will use the `*_unchecked` wasmer functions for
    /// loading modules from disk.
    pub fn set_module_unchecked(&mut self, unchecked: bool) {
        self.inner
            .lock()
            .unwrap()
            .fs_cache
            .set_module_unchecked(unchecked);
    }

    pub fn stats(&self) -> Stats {
        self.inner.lock().unwrap().stats
    }

    pub fn pinned_metrics(&self) -> PinnedMetrics {
        let cache = self.inner.lock().unwrap();
        let per_module: Vec<(CacheKey, PerModuleMetrics)> = cache
            .pinned_memory_cache
            .iter()
            .map(|(checksum, module)| {
                let metrics = PerModuleMetrics {
                    hits: module.hits,
                    size: module.module.size_estimate,
                };

                (CacheKey::Checksum(*checksum), metrics)
            })
            .collect();

        #[cfg(feature = "zk")]
        {
            let mut pm: Vec<(CacheKey, PerModuleMetrics)> = cache
                .pinned_memory_cache
                .iter_circuits()
                .map(|(checksum, zk)| {
                    let metrics = PerModuleMetrics {
                        hits: zk.hits,
                        size: zk.circuit.size_estimate,
                    };

                    (CacheKey::CircuitKey(*checksum), metrics)
                })
                .collect();
            pm.extend_from_slice(&per_module);
            PinnedMetrics { per_module: pm }
        }
        #[cfg(not(feature = "zk"))]
        PinnedMetrics { per_module }
    }

    pub fn metrics(&self) -> Metrics {
        let cache = self.inner.lock().unwrap();
        Metrics {
            stats: cache.stats,
            elements_pinned_memory_cache: cache.pinned_memory_cache.len(),
            elements_memory_cache: cache.memory_cache.len(),
            size_pinned_memory_cache: cache.pinned_memory_cache.size(),
            size_memory_cache: cache.memory_cache.size(),
        }
    }

    /// Takes a Wasm bytecode and stores it to the cache.
    ///
    /// This performs static checks, compiles the bytescode to a module and
    /// stores the Wasm file on disk.
    ///
    /// This does the same as [`Cache::save_wasm_unchecked`] plus the static checks.
    /// When a Wasm blob is stored the first time, use this function.
    #[deprecated = "Use `store_code(wasm, true, true)` instead"]
    pub fn save_wasm(&self, wasm: &[u8]) -> VmResult<Checksum> {
        self.store_code(wasm, true, true)
    }

    /// Takes a Wasm bytecode and stores it to the cache.
    ///
    /// This is for regular CosmWasm contracts without verifying keys.
    /// For ZK-enabled contracts, use `store_code_with_circuit()` instead.
    ///
    /// This performs static checks if `checked` is `true`,
    /// compiles the bytescode to a module and
    /// stores the Wasm file on disk if `persist` is `true`.
    ///
    /// Only set `checked = false` when a Wasm blob is stored which was previously checked
    /// (e.g. as part of state sync).
    pub fn store_code(&self, wasm: &[u8], checked: bool, persist: bool) -> VmResult<Checksum> {
        if checked {
            check_wasm(
                wasm,
                &self.available_capabilities,
                &self.wasm_limits,
                crate::internals::Logger::Off,
            )?;
        }

        let (module, _) = compile_module(wasm, None)?;

        if persist {
            self.save_to_disk(wasm, &module)
        } else {
            Ok(Checksum::generate(wasm))
        }
    }

    /// Takes a Wasm bytecode and stores it to the cache.
    ///
    /// This compiles the bytescode to a module and
    /// stores the Wasm file on disk.
    ///
    /// This does the same as [`Cache::save_wasm`] but without the static checks.
    /// When a Wasm blob is stored which was previously checked (e.g. as part of state sync),
    /// use this function.
    #[deprecated = "Use `store_code(wasm, false, true)` instead"]
    pub fn save_wasm_unchecked(&self, wasm: &[u8]) -> VmResult<Checksum> {
        self.store_code(wasm, false, true)
    }

    fn save_to_disk(&self, wasm: &[u8], module: &Module) -> VmResult<Checksum> {
        let mut cache = self.inner.lock().unwrap();
        let checksum = save_wasm_to_disk(&cache.wasm_path, wasm)?;
        cache.fs_cache.store(&checksum, module)?;
        Ok(checksum)
    }

    /// Removes the Wasm blob for the given checksum from disk and its
    /// compiled module from the file system cache.
    ///
    /// Also removes the VK file if present.
    /// The existence of the original code is required since the caller (wasmd)
    /// has to keep track of which entries we have here.
    pub fn remove_wasm(&self, checksum: &Checksum) -> VmResult<()> {
        let mut cache = self.inner.lock().unwrap();
        // Remove compiled module & vk from disk.
        // Remove compiled moduled from disk (if it exists).
        // Here we could also delete from memory caches but this is not really
        // necessary as they are pushed out from the LRU over time or disappear
        // when the node process restarts.
        cache.fs_cache.remove(checksum)?;
        remove_wasm_from_disk(&cache.wasm_path, checksum)?;

        Ok(())
    }

    /// Performs static anlyzation on this Wasm without compiling or instantiating it.
    ///
    /// Once the contract was stored via [`Cache::store_code`], this can be called at any point in time.
    /// It does not depend on any caching of the contract.
    pub fn analyze(&self, checksum: &Checksum) -> VmResult<AnalysisReport> {
        // Here we could use a streaming deserializer to slightly improve performance. However, this way it is DRYer.
        let wasm = self.load_wasm(checksum)?;
        let module = ParsedWasm::parse(&wasm)?;
        let exports = module.exported_function_names(None);

        let entrypoints = exports
            .iter()
            .filter_map(|export| Entrypoint::from_str(export).ok())
            .collect();

        Ok(AnalysisReport {
            has_ibc_entry_points: REQUIRED_IBC_EXPORTS
                .iter()
                .all(|required| exports.contains(required.as_ref())),
            entrypoints,
            required_capabilities: required_capabilities_from_module(&module)
                .into_iter()
                .collect(),
            contract_migrate_version: module.contract_migrate_version,
        })
    }

    /// Pins a Module that was previously stored via [`Cache::store_code`].
    ///
    /// The module is looked up first in the file system cache. If not found,
    /// the code is loaded from the file system, compiled, and stored into the
    /// pinned cache.
    ///
    /// If the given contract for the given checksum is not found, or the content
    /// does not match the checksum, an error is returned.
    pub fn pin(&self, checksum: &Checksum) -> VmResult<()> {
        let mut cache = self.inner.lock().unwrap();

        if cache.pinned_memory_cache.has(checksum) {
            return Ok(());
        }

        // We don't load from the memory cache because we had to create new store here and
        // serialize/deserialize the artifact to get a full clone. Could be done but adds some code
        // for a not-so-relevant use case.

        // Try to get module from file system cache
        if let Some(cached_module) = cache
            .fs_cache
            .load(checksum, Some(self.instance_memory_limit))?
        {
            cache.stats.hits_fs_cache = cache.stats.hits_fs_cache.saturating_add(1);
            cache.pinned_memory_cache.store(checksum, cached_module)?;

            return Ok(());
        }

        // Re-compile from original Wasm bytecode
        let wasm = self.load_wasm_with_path(&cache.wasm_path, checksum)?;
        cache.stats.misses = cache.stats.misses.saturating_add(1);
        {
            // Module will run with a different engine, so we can set memory limit to None
            let compiling_engine = make_compiling_engine(None, None);
            // This module cannot be executed directly as it was not created with the runtime engine
            let module = compile(&compiling_engine, &wasm)?;
            cache.fs_cache.store(checksum, &module)?;
        }

        // This time we'll hit the file-system cache.
        let Some(cached_module) = cache
            .fs_cache
            .load(checksum, Some(self.instance_memory_limit))?
        else {
            return Err(VmError::generic_err(
                "Can't load module from file system cache after storing it to file system cache (pin)",));
        };

        cache.pinned_memory_cache.store(checksum, cached_module)
    }

    /// Unpins a Module, i.e. removes it from the pinned memory cache.
    ///
    /// Not found IDs are silently ignored, and no integrity check (checksum validation) is done
    /// on the removed value.
    pub fn unpin(&self, checksum: &Checksum) -> VmResult<()> {
        self.inner
            .lock()
            .unwrap()
            .pinned_memory_cache
            .remove(checksum)
    }

    /// Synchronizes the set of pinned **Wasm modules** with the provided `checksums`.
    ///
    /// Upstream CosmWasm v3.0.x API used by wasmd `pinCode` / `InitializePinnedCodes`
    /// (via wasmvm `SyncPinnedCodes`). Pins missing modules and unpins extras.
    pub fn sync_pinned_codes(&self, checksums: &[Checksum]) -> VmResult<()> {
        let mut add: Vec<Checksum> = vec![];
        let mut del: Vec<Checksum> = vec![];
        {
            let cache = self.inner.lock().unwrap();
            for (checksum, _) in cache.pinned_memory_cache.iter() {
                if !checksums.contains(checksum) {
                    del.push(*checksum);
                }
            }
            for checksum in checksums {
                if !cache.pinned_memory_cache.has(checksum) {
                    add.push(*checksum);
                }
            }
        }
        for checksum in &add {
            self.pin(checksum)?;
        }
        for checksum in &del {
            self.unpin(checksum)?;
        }
        Ok(())
    }

    /// Synchronizes the set of pinned **circuits** (72-byte keys) with `circuit_keys`.
    ///
    /// Circuit analogue of [`Self::sync_pinned_codes`] — for wasmd bulk pin/unpin and
    /// node restart re-pin without N individual `pin_circuit` races.
    #[cfg(feature = "zk")]
    pub fn sync_pinned_circuits(&self, circuit_keys: &[[u8; 72]]) -> VmResult<()> {
        let mut add: Vec<[u8; 72]> = vec![];
        let mut del: Vec<[u8; 72]> = vec![];
        {
            let cache = self.inner.lock().unwrap();
            for (key, _) in cache.pinned_memory_cache.iter_circuits() {
                if !circuit_keys.iter().any(|k| k == key) {
                    del.push(*key);
                }
            }
            for key in circuit_keys {
                if !cache.pinned_memory_cache.has_circuit(key) {
                    add.push(*key);
                }
            }
        }
        for key in &add {
            self.pin_circuit(key)?;
        }
        for key in &del {
            self.unpin_circuit(key)?;
        }
        Ok(())
    }

    /// Returns an Instance tied to a previously saved Wasm.
    ///
    /// It takes a module from cache or Wasm code and instantiates it.
    pub fn get_instance(
        &self,
        checksum: &Checksum,
        backend: Backend<A, S, Q>,
        options: InstanceOptions,
    ) -> VmResult<Instance<A, S, Q>> {
        let (module, store) = self.get_module(checksum)?;

        #[cfg(feature = "zk")]
        let circuit_loader = Some(self.circuit_loader());
        #[cfg(not(feature = "zk"))]
        let circuit_loader = None;

        let instance = Instance::from_module(
            store,
            &module,
            backend,
            options.gas_limit,
            None,
            Some(&self.instantiation_lock),
            circuit_loader,
        )?;
        Ok(instance)
    }

    /// Builds a Path A circuit loader that can be installed on a contract
    /// [`Environment`] so proof verification uses the host cache directly.
    #[cfg(feature = "zk")]
    pub fn circuit_loader(&self) -> crate::environment::CircuitLoader {
        let inner = Arc::clone(&self.inner);
        Arc::new(move |circuit_key: [u8; 72]| {
            // Keep the lock scope tight: clone CachedCircuit out, then drop.
            let mut cache = inner.lock().unwrap();
            // pinned
            if let Some(czk) = cache.pinned_memory_cache.load_circuit(&circuit_key)? {
                cache.stats.hits_pinned_memory_cache =
                    cache.stats.hits_pinned_memory_cache.saturating_add(1);
                return Ok(Some(czk.vk));
            }
            // memory LRU
            if let Some(czk) = cache.memory_cache.load_circuit(&circuit_key)? {
                cache.stats.hits_memory_cache = cache.stats.hits_memory_cache.saturating_add(1);
                return Ok(Some(czk.vk));
            }
            // filesystem (deserialized on load)
            if let Some(czk) = cache.fs_cache.load_circuit(&circuit_key)? {
                cache.stats.hits_fs_cache = cache.stats.hits_fs_cache.saturating_add(1);
                let _ = cache.memory_cache.store_circuit(&circuit_key, &czk);
                return Ok(Some(czk.vk));
            }
            // Split-file reconstruct (param + vk on disk under wasm_path)
            let wasm_path = cache.wasm_path.clone();
            drop(cache);
            let param_key: [u8; 36] = circuit_key[..36]
                .try_into()
                .map_err(|_| VmError::generic_err("invalid circuit key (param half)"))?;
            let vk_key: [u8; 36] = circuit_key[36..]
                .try_into()
                .map_err(|_| VmError::generic_err("invalid circuit key (vk half)"))?;
            let param_path = wasm_path
                .join(ZK_PARAM_DIR)
                .join(hex::encode(param_key))
                .with_extension("bin");
            let vk_path = wasm_path
                .join(ZK_VK_DIR)
                .join(hex::encode(vk_key))
                .with_extension("bin");
            let circuit_path = wasm_path
                .join(ZK_CIRCUIT_DIR)
                .join(hex::encode(circuit_key))
                .with_extension("bin");
            if !vk_path.exists() || !circuit_path.exists() {
                return Ok(None);
            }
            let full = fs::read(&circuit_path)
                .map_err(|e| VmError::cache_err(format!("read circuit for verify: {e}")))?;
            let footer = check_circuit(&full).map_err(VmError::zk_err)?;
            // Empty-param (param_len=0): allow missing or empty param file;
            // do not require a Halo2 k header.
            let param_bytes = if footer.param_len == 0 {
                if param_path.exists() {
                    fs::read(&param_path)
                        .map_err(|e| VmError::cache_err(format!("read param for verify: {e}")))?
                } else {
                    Vec::new()
                }
            } else {
                if !param_path.exists() {
                    return Ok(None);
                }
                fs::read(&param_path)
                    .map_err(|e| VmError::cache_err(format!("read param for verify: {e}")))?
            };
            let vk_body = fs::read(&vk_path)
                .map_err(|e| VmError::cache_err(format!("read vk for verify: {e}")))?;
            let vk =
                zk_cosmwasm::AnyVerifyingKey::from_split_bytes(&param_bytes, &vk_body, &footer)
                    .map_err(VmError::zk_err)?;
            // Warm caches for next call
            let mut cache = inner.lock().unwrap();
            let size_estimate = param_bytes.len() + vk_body.len() + COSMWASM_FOOTER_LENGTH;
            let cached = CachedCircuit {
                vk: vk.clone(),
                size_estimate,
            };
            let _ = cache.memory_cache.store_circuit(&circuit_key, &cached);
            Ok(Some(vk))
        })
    }

    /// Returns a module tied to a previously saved Wasm.
    /// Depending on availability, this is either generated from a memory cache, file system cache or Wasm code.
    /// This is part of `get_instance` but pulled out to reduce the locking time.
    fn get_module(&self, checksum: &Checksum) -> VmResult<(Module, Store)> {
        let mut cache = self.inner.lock().unwrap();
        // Try to get module from the pinned memory cache
        if let Some(element) = cache.pinned_memory_cache.load(checksum)? {
            cache.stats.hits_pinned_memory_cache =
                cache.stats.hits_pinned_memory_cache.saturating_add(1);
            let CachedModule {
                module,
                engine,
                size_estimate: _,
            } = element;
            let store = Store::new(engine);
            return Ok((module, store));
        }

        // Get module from memory cache
        if let Some(element) = cache.memory_cache.load(checksum)? {
            cache.stats.hits_memory_cache = cache.stats.hits_memory_cache.saturating_add(1);
            let CachedModule {
                module,
                engine,
                size_estimate: _,
            } = element;
            let store = Store::new(engine);
            return Ok((module, store));
        }

        // Get module from file system cache
        if let Some(cached_module) = cache
            .fs_cache
            .load(checksum, Some(self.instance_memory_limit))?
        {
            cache.stats.hits_fs_cache = cache.stats.hits_fs_cache.saturating_add(1);

            cache.memory_cache.store(checksum, cached_module.clone())?;

            let CachedModule {
                module,
                engine,
                size_estimate: _,
            } = cached_module;
            let store = Store::new(engine);
            return Ok((module, store));
        }

        // Re-compile module from wasm
        //
        // This is needed for chains that upgrade their node software in a way that changes the module
        // serialization format. If you do not replay all transactions, previous calls of `store_code`
        // stored the old module format.
        let wasm = self.load_wasm_with_path(&cache.wasm_path, checksum)?;
        cache.stats.misses = cache.stats.misses.saturating_add(1);
        {
            // Module will run with a different engine, so we can set memory limit to None
            let compiling_engine = make_compiling_engine(None, None);
            // This module cannot be executed directly as it was not created with the runtime engine
            let module = compile(&compiling_engine, &wasm)?;
            cache.fs_cache.store(checksum, &module)?;
        }

        // This time we'll hit the file-system cache.
        let Some(cached_module) = cache
            .fs_cache
            .load(checksum, Some(self.instance_memory_limit))?
        else {
            return Err(VmError::generic_err(
                "Can't load module from file system cache after storing it to file system cache (get_module)",
            ));
        };
        cache.memory_cache.store(checksum, cached_module.clone())?;

        let CachedModule {
            module,
            engine,
            size_estimate: _,
        } = cached_module;
        let store = Store::new(engine);
        Ok((module, store))
    }

    // Helper to produce a dummy checksum (same as used for missing VK)
    fn store_wasm_to_disk(&self, dir: &PathBuf, wasm: Vec<u8>) -> VmResult<(Module, Checksum)> {
        // Compile and store WASM
        Ok((
            compile_module(&wasm, None)?.0,
            save_wasm_to_disk(dir, &wasm)?,
        ))
    }

    /// Retrieves a Wasm blob that was previously stored via [`Cache::store_code`].
    /// When the cache is instantiated with the same base dir, this finds Wasm files on disc across multiple cache instances (i.e. node restarts).
    /// This function is public to allow a checksum to Wasm lookup in the blockchain.
    ///
    /// If the given ID is not found or the content does not match the hash (=ID), an error is returned.
    pub fn load_wasm(&self, checksum: &Checksum) -> VmResult<Vec<u8>> {
        self.load_wasm_with_path(&self.inner.lock().unwrap().wasm_path, checksum)
    }

    fn load_wasm_with_path(&self, wasm_path: &Path, checksum: &Checksum) -> VmResult<Vec<u8>> {
        let code = load_wasm_from_disk(wasm_path, checksum)?;
        // verify hash matches (integrity check)
        if Checksum::generate(&code) != *checksum {
            Err(VmError::integrity_err())
        } else {
            Ok(code)
        }
    }
}

#[cfg(feature = "zk")]
impl<A, S, Q> Cache<A, S, Q>
where
    A: BackendApi + 'static, // 'static is needed by `impl<…> Instance`
    S: Storage + 'static,    // 'static is needed by `impl<…> Instance`
    Q: Querier + 'static,    // 'static is needed by `impl<…> Instance`
{
    fn save_vk_params_to_disk(
        &self,
        cache: &mut std::sync::MutexGuard<'_, CacheInner>,
        p: &[u8],
    ) -> VmResult<Checksum> {
        save_vk_params_to_disk(&cache.param_path(), p)
    }

    /// Store param bytes independently, without a circuit.
    ///
    /// # Halo2 (non-empty)
    /// Reads `k` from the first 4 bytes of the halo2 params (u32 LE) and uses
    /// `appstate_key = BE([prover_id=0, curve_id=0, k, 0])`.
    ///
    /// # Empty-param path (Groth16 / BN254)
    /// When `p` is empty, skips the k-header parse entirely and stores an empty
    /// file under `zk_param/{param_key}.bin` with
    /// `appstate_key = BE([0, 0, 0, 0])` and `param_checksum = SHA256([])`.
    /// Prefer [`Self::store_param_with_meta`] (or `store_circuit` with a full
    /// footer) when the real prover/curve/k prefix is known.
    ///
    /// Returns the 36-byte param_key = `[appstate_key_le][SHA256(params)]`.
    pub fn store_param(&self, p: &[u8]) -> VmResult<[u8; 36]> {
        if p.is_empty() {
            // Empty-param convention: no Halo2 k header.
            return self.store_param_with_meta(p, 0, 0, 0);
        }
        // Extract k from the halo2 params header (first 4 bytes, u32 LE)
        if p.len() < 4 {
            return Err(VmError::cache_err("param bytes too short for k header"));
        }
        let k_bytes: [u8; 4] = p[..4].try_into().expect("4-byte k");
        let k = u32::from_le_bytes(k_bytes) as u8;
        self.store_param_with_meta(p, 0, 0, k)
    }

    /// Store param bytes using explicit footer-derived key metadata.
    ///
    /// `appstate_key = BE([prover_id, curve_id, k, 0])`. Empty `p` is allowed
    /// (writes a zero-length `zk_param` file; checksum is `SHA256([])`).
    pub fn store_param_with_meta(
        &self,
        p: &[u8],
        prover_id: u8,
        curve_id: u8,
        k: u8,
    ) -> VmResult<[u8; 36]> {
        let appstate_key = u32::from_be_bytes([prover_id, curve_id, k, 0]);
        let param_checksum = Checksum::generate(p);

        let mut param_key = [0u8; 36];
        param_key[..4].copy_from_slice(&appstate_key.to_le_bytes());
        param_key[4..].copy_from_slice(param_checksum.as_slice());

        let mut cache = self.inner.lock().unwrap();
        let param_path = cache
            .param_path()
            .join(hex::encode(param_key))
            .with_extension("bin");
        if let Some(parent) = param_path.parent() {
            mkdir_p(parent).map_err(|_e| VmError::cache_err("Error creating param dir"))?;
        }
        {
            let mut file = OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .open(&param_path)
                .map_err(|e| VmError::cache_err(format!("Error opening param file: {e}")))?;
            file.write_all(p)
                .map_err(|e| VmError::cache_err(format!("Error writing param file: {e}")))?;
        }
        cache.pinned_memory_cache.store_param(
            &param_key,
            crate::modules::CachedParam::from_bytes(p.to_vec()),
        )?;
        cache.memory_cache.store_param(
            &param_key,
            &crate::modules::CachedParam::from_bytes(p.to_vec()),
        )?;

        Ok(param_key)
    }

    pub fn remove_vk_params(
        &self,
        cache: &mut std::sync::MutexGuard<'_, CacheInner>,
        param_file_key: &[u8; 36],
    ) -> VmResult<()> {
        // Remove compiled module & vk from disk.
        // Remove compiled moduled from disk (if it exists).
        // Here we could also delete from memory caches but this is not really
        // necessary as they are pushed out from the LRU over time or disappear
        // when the node process restarts.
        cache.fs_cache.remove_params(param_file_key)?;
        cache.pinned_memory_cache.remove_param(param_file_key)?;
        self.remove_vk_params_from_disk(&cache.wasm_path, param_file_key)?;
        Ok(())
    }

    /// Remove a VK file from disk if the path exists
    #[cfg(feature = "zk")]
    fn remove_vk_params_from_disk(
        &self,
        dir: impl Into<PathBuf>,
        param_file_key: &[u8; 36],
    ) -> VmResult<()> {
        let path: PathBuf = self.param_path(dir, param_file_key);
        println!("{}", path.to_str().unwrap());

        let circuit_path = path.with_extension("bin");
        println!("{}", circuit_path.to_str().unwrap());

        let path_exists = path.exists();
        let circuit_path_exists = circuit_path.exists();
        if !path_exists && !circuit_path_exists {
            return Err(VmError::cache_err("Circuit file does not exist"));
        }
        if path.exists() {
            println!("removing file");
            std::fs::remove_file(&path)
                .map_err(|e| VmError::cache_err(format!("Error removing VK file: {}", e)))?;
            println!("file removed");
        }

        Ok(())
    }
}

#[cfg(feature = "zk")]
impl<A, S, Q> Cache<A, S, Q>
where
    A: BackendApi + 'static, // 'static is needed by `impl<…> Instance`
    S: Storage + 'static,    // 'static is needed by `impl<…> Instance`
    Q: Querier + 'static,    // 'static is needed by `impl<…> Instance`
{
    /// Store a circuit blob.
    ///
    /// * `persist=true` — write split/monolithic files + pin (DeliverTx path).
    /// * `persist=false` — **memory-only** warm (H-03 / KD-sem intended model):
    ///   deserialize VK into the in-memory LRU, **no** disk, **no** pin.
    ///   Used by `SimulateStoreCircuit`. Still runs full `check_circuit`.
    pub fn store_circuit(&self, zk: &[u8], persist: bool) -> VmResult<[u8; 72]> {
        let foot = check_circuit(zk)?;
        let circuit_key = foot.to_circuit_key();

        if persist {
            let (filename, circuitname): ([[u8; 36]; 2], [u8; 72]) =
                self.save_circuit_to_disk(zk, &foot)?;
            if filename[0] != foot.to_param_key() || filename[1] != foot.to_vk_key() {
                return Err(VmError::cache_err("circuit key mismatch after save"));
            }
            if circuitname != circuit_key {
                return Err(VmError::cache_err("circuitname != footer.to_circuit_key()"));
            }
            self.pin_circuit(&circuitname)?;
            Ok(circuitname)
        } else {
            // H-03: memory-only — deserialise + LRU, no disk/pin.
            let vk = zk_cosmwasm::AnyVerifyingKey::try_from(zk).map_err(VmError::zk_err)?;
            // H-06 partial: identity of deserialized VK must match footer key.
            if vk.circuit_key() != circuit_key {
                return Err(VmError::cache_err(
                    "deserialized circuit_key does not match footer.to_circuit_key()",
                ));
            }
            let size_estimate = zk.len();
            let cached = crate::modules::CachedCircuit { vk, size_estimate };
            let mut cache = self.inner.lock().unwrap();
            cache.memory_cache.store_circuit(&circuit_key, &cached)?;
            Ok(circuit_key)
        }
    }

    // pub fn remove_circuit(&self, checksum: &[u8; 72]) -> VmResult<()> {
    //     let mut cache = self.inner.lock().unwrap();
    //     tracing::debug!("remove_circuit_from_disk ");
    //     self.remove_circuit_from_disk(&cache.wasm_path, checksum)?;

    //     Ok(())
    // }

    /// Saves params, cs+vk, and the full circuit under their respective dirs.
    fn save_circuit_to_disk(
        &self,
        c: &[u8],
        cf: &CircuitFooter,
    ) -> VmResult<([[u8; 36]; 2], [u8; 72])> {
        let cache = self.inner.lock().unwrap();
        save_circuit_parts(
            &cache.param_path(),
            &cache.vk_path(),
            &cache.circuit_path(),
            c,
            *cf,
        )
    }

    /// Removes the Wasm blob for the given checksum from disk and its
    /// compiled module from the file system cache.
    ///
    /// Also removes the VK file if present.
    /// The existence of the original code is required since the caller (wasmd)
    /// has to keep track of which entries we have here.
    pub fn remove_circuit(&self, circuit_file_key: &[u8; 72]) -> VmResult<()> {
        let mut cache = self.inner.lock().unwrap();
        let param_key: [u8; 36] = circuit_file_key[..36]
            .try_into()
            .map_err(|_| VmError::cache_err("invalid circuit key (param half)"))?;
        let vk_key: [u8; 36] = circuit_file_key[36..]
            .try_into()
            .map_err(|_| VmError::cache_err("invalid circuit key (vk half)"))?;

        cache.fs_cache.remove_circuit(circuit_file_key)?;
        cache.pinned_memory_cache.remove_circuit(circuit_file_key)?;
        tracing::debug!("remove_circuit_from_disk ");
        self.remove_circuit_from_disk(&cache.circuit_path(), circuit_file_key)?;

        let param_path = cache
            .param_path()
            .join(hex::encode(param_key))
            .with_extension("bin");
        let vk_path = cache
            .vk_path()
            .join(hex::encode(vk_key))
            .with_extension("bin");
        let _ = std::fs::remove_file(&param_path);
        let _ = std::fs::remove_file(&vk_path);

        Ok(())
    }

    /// Pins a circuit that was previously stored via [`Cache::store_circuit`].
    ///
    /// The module is looked up first in the file system cache. If not found,
    /// the code is loaded from the file system, compiled, and stored into the
    /// pinned cache.
    ///
    /// If the given contract for the given checksum is not found, or the content
    /// does not match the checksum, an error is returned.

    /// Pins a Module that was previously stored via [`Cache::store_code`].
    ///
    /// The module is looked up first in the file system cache. If not found,
    /// the code is loaded from the file system, compiled, and stored into the
    /// pinned cache.
    ///
    /// If the given contract for the given checksum is not found, or the content
    /// does not match the checksum, an error is returned.
    pub fn pin_circuit(&self, circuit_file_key: &[u8; 72]) -> VmResult<()> {
        let mut cache: std::sync::MutexGuard<'_, CacheInner> = self.inner.lock().unwrap();
        self._pin_circuit(circuit_file_key, &mut cache)
    }

    pub fn _pin_circuit(
        &self,
        circuit_file_key: &[u8; 72],
        cache: &mut std::sync::MutexGuard<'_, CacheInner>,
    ) -> VmResult<()> {
        if cache.pinned_memory_cache.has_circuit(circuit_file_key) {
            return Ok(());
        }
        println!("didnt have in pinned memory");
        cache.stats.misses += 1;

        // We don't load from the memory cache because we had to create new store here and
        // serialize/deserialize the artifact to get a full clone. Could be done but adds some code
        // for a not-so-relevant use case.

        // Try to get module from file system cache
        if let Some(cached_circuit) = cache.fs_cache.load_circuit(circuit_file_key)? {
            println!("found in filesystem cache");
            cache.stats.hits_fs_cache = cache.stats.hits_fs_cache.saturating_add(1);
            cache
                .pinned_memory_cache
                .store_circuit(circuit_file_key, cached_circuit)?;

            return Ok(());
        }

        // Re-compile from the full circuit bytecode information.
        //IMPORTANT: this would be if the circuit has not yet been compiled yet by the appstate (contract usage once, memeory eviction)
        let zk = self.load_circuit_with_path(
            &cache.wasm_path,
            &circuit_file_key[..36].try_into().expect("msg"),
            &circuit_file_key[36..].try_into().expect("msg"),
        )?;
        cache.stats.misses = cache.stats.misses.saturating_add(1);
        cache
            .fs_cache
            .store_circuit(circuit_file_key, &zk.serialized_to_vec())?;

        // // This time we'll hit the file-system cache.
        let Some(verifying_key) = cache.fs_cache.load_circuit(circuit_file_key)? else {
            return Err(VmError::generic_err(
                "Can't load module from file system cache after storing it to file system cache (pin)",));
        };

        cache
            .pinned_memory_cache
            .store_circuit(circuit_file_key, verifying_key)
    }

    /// Unpin a circuit: drop **pin residency only** (H-04 / Wasm-like intent).
    /// Disk artifacts and fs_cache module bytes remain for later pin/load.
    /// Full deletion remains [`Self::remove_circuit`].
    pub fn unpin_circuit(&self, circuit_file_key: &[u8; 72]) -> VmResult<()> {
        let mut cache = self.inner.lock().unwrap();
        cache.pinned_memory_cache.remove_circuit(circuit_file_key)?;
        Ok(())
    }

    /// Load a verifying key from disk
    pub fn load_circuit(&self, circuit_file_key: &[u8; 72]) -> VmResult<Option<CachedCircuit>> {
        let mut cache = self.inner.lock().unwrap();
        // Try to get module from the pinned memory cache
        if let Some(czk) = cache.pinned_memory_cache.load_circuit(circuit_file_key)? {
            cache.stats.hits_pinned_memory_cache =
                cache.stats.hits_pinned_memory_cache.saturating_add(1);
            return Ok(Some(czk));
        }

        // Get module from memory cache
        if let Some(czk) = cache.memory_cache.load_circuit(circuit_file_key)? {
            cache.stats.hits_memory_cache = cache.stats.hits_memory_cache.saturating_add(1);
            return Ok(Some(czk));
        }

        // Get module from file system cache
        if let Some(czk) = cache.fs_cache.load_circuit(circuit_file_key)? {
            cache.stats.hits_fs_cache = cache.stats.hits_fs_cache.saturating_add(1);
            cache.memory_cache.store_circuit(circuit_file_key, &czk)?;
            return Ok(Some(czk));
        }

        // Re-compile module from wasm
        //
        // This is needed for chains that upgrade their node software in a way that changes the module
        // serialization format. If you do not replay all transactions, previous calls of `store_code`
        // stored the old module format.
        let zk = self.load_circuit_with_path(
            &cache.wasm_path,
            &circuit_file_key[..36].try_into().expect("msg"),
            &circuit_file_key[36..].try_into().expect("msg"),
        )?;
        cache.stats.misses = cache.stats.misses.saturating_add(1);
        {
            cache
                .fs_cache
                .store_circuit(circuit_file_key, &zk.serialized_to_vec())?;
        }

        // This time we'll hit the file-system cache.
        let Some(czk) = cache.fs_cache.load_circuit(circuit_file_key)? else {
            return Err(VmError::generic_err(
                "Can't load module from file system cache after storing it to file system cache (load_circuit)",
            ));
        };
        cache.memory_cache.store_circuit(circuit_file_key, &czk)?;

        // let CachedCircuit { vk, .. } = element;
        Ok(Some(czk))
    }

    /// Check if a VK exists for a given circuit_key
    pub fn has_circuit(&self, circuit_file_key: &[u8; 72]) -> bool {
        let cache = self.inner.lock().unwrap();
        // TODO::IMPORTANT:: implement method that is aware if possible of reconstructing requiested circuit if not full bytes loaded in cache
        let circuit_path = self.circuit_path(&cache.circuit_path(), circuit_file_key);
        circuit_path.exists()
    }

    fn circuit_path(&self, dir: impl Into<PathBuf>, circuit_file_key: &[u8; 72]) -> PathBuf {
        dir.into()
            .join(hex::encode(circuit_file_key))
            .with_extension("bin")
    }
    fn param_path(&self, dir: impl Into<PathBuf>, param_file_key: &[u8; 36]) -> PathBuf {
        dir.into()
            .join(hex::encode(param_file_key))
            .with_extension("bin")
    }
    fn vk_path(&self, dir: impl Into<PathBuf>, checksum: &Checksum) -> PathBuf {
        dir.into().join(checksum.to_hex()).with_extension("bin")
    }

    // /// Stores vk keys to their dedicated path in dir.
    // fn store_circuit_to_disk(
    //     &self,
    //     dir: impl Into<PathBuf>,
    //     vk: &SerializedCircuitData,
    // ) -> VmResult<Checksum> {
    //     use crate::COSMWASM_FOOTER_LENGTH;
    //     let len = vk.body.len();
    //     // hash is last 32 bytes
    //     let hash = &vk.footer[COSMWASM_FOOTER_LENGTH - 32..]
    //         .try_into()
    //         .map_err(|e: cosmwasm_std::ChecksumError| VmError::cache_err(e.to_string()))?;
    //     let path = self.zk_path(dir, hash);

    //     let mut file_content: Vec<u8> = Vec::with_capacity(len + COSMWASM_FOOTER_LENGTH);
    //     file_content.extend_from_slice(&vk.body);
    //     file_content.extend_from_slice(&vk.footer);

    //     let mut file = OpenOptions::new()
    //         .write(true)
    //         .create(true)
    //         .truncate(true)
    //         .open(&path)
    //         .map_err(|e| VmError::cache_err(format!("Error creating VK file: {}", e)))?;

    //     file.write_all(&file_content)
    //         .map_err(|e| VmError::cache_err(format!("Error writing VK file: {}", e)))?;

    //     Ok(*hash)
    // }

    /// Load a circuit by reconstructing from split param / vk files under
    /// `wasm_path/{zk_param,zk_vk}/`, falling back to the monolithic circuit
    /// blob under `wasm_path/zk_circuit/` when present.
    fn load_circuit_with_path(
        &self,
        wasm_path: &Path,
        param_file_key: &[u8; 36],
        vk_file_key: &[u8; 36],
    ) -> VmResult<zk_cosmwasm::SerializedCircuitData> {
        let mut circuit_key = [0u8; 72];
        circuit_key[..36].copy_from_slice(param_file_key);
        circuit_key[36..].copy_from_slice(vk_file_key);

        let param_path = wasm_path
            .join(ZK_PARAM_DIR)
            .join(hex::encode(param_file_key))
            .with_extension("bin");
        let vk_path = wasm_path
            .join(ZK_VK_DIR)
            .join(hex::encode(vk_file_key))
            .with_extension("bin");
        let circuit_path = wasm_path
            .join(ZK_CIRCUIT_DIR)
            .join(hex::encode(circuit_key))
            .with_extension("bin");

        // Prefer split reconstruction so param files are the source of truth.
        // Empty-param circuits (param_len=0) may omit the param file entirely.
        if vk_path.exists() && circuit_path.exists() {
            let full = fs::read(&circuit_path)
                .map_err(|e| VmError::cache_err(format!("Error reading circuit file: {e}")))?;
            let footer = check_circuit(&full).map_err(VmError::zk_err)?;
            // H-06: re-bind path key to footer-derived identity.
            let derived = footer.to_circuit_key();
            if derived != circuit_key {
                return Err(VmError::cache_err(format!(
                    "circuit file key {} does not match footer.to_circuit_key() {}",
                    hex::encode(circuit_key),
                    hex::encode(derived)
                )));
            }

            let param_bytes = if footer.param_len == 0 {
                if param_path.exists() {
                    fs::read(&param_path)
                        .map_err(|e| VmError::cache_err(format!("Error reading param file: {e}")))?
                } else {
                    Vec::new()
                }
            } else if param_path.exists() {
                fs::read(&param_path)
                    .map_err(|e| VmError::cache_err(format!("Error reading param file: {e}")))?
            } else {
                // Non-empty params required but missing — fall through to monolithic.
                Vec::new()
            };

            let use_split = footer.param_len == 0 || param_path.exists();
            if use_split {
                let vk_body_bytes = fs::read(&vk_path)
                    .map_err(|e| VmError::cache_err(format!("Error reading vk file: {e}")))?;

                if param_bytes.len() as u32 != footer.param_len {
                    return Err(VmError::cache_err(format!(
                        "param file length {} != footer.param_len {}",
                        param_bytes.len(),
                        footer.param_len
                    )));
                }
                let expected_vk_body =
                    (footer.cs_len as usize).saturating_add(footer.vk_len as usize);
                if vk_body_bytes.len() != expected_vk_body {
                    return Err(VmError::cache_err(format!(
                        "vk file length {} != cs_len+vk_len {}",
                        vk_body_bytes.len(),
                        expected_vk_body
                    )));
                }
                if Checksum::generate(&param_bytes).as_slice() != footer.param_checksum {
                    return Err(VmError::cache_err(
                        "calculated param hash doesn't match stored hash",
                    ));
                }
                if Checksum::generate(&vk_body_bytes).as_slice() != footer.vk_checksum {
                    return Err(VmError::cache_err(
                        "calculated vk hash doesn't match stored hash",
                    ));
                }

                // Ensure the split material actually deserializes before caching.
                let _vk = zk_cosmwasm::AnyVerifyingKey::from_split_bytes(
                    &param_bytes,
                    &vk_body_bytes,
                    &footer,
                )
                .map_err(VmError::zk_err)?;

                let mut body = Vec::with_capacity(param_bytes.len() + vk_body_bytes.len());
                body.extend_from_slice(&param_bytes);
                body.extend_from_slice(&vk_body_bytes);
                return Ok(SerializedCircuitData::new(&body, &footer.to_bytes()));
            }
        }

        // Monolithic fallback
        match self.load_circuit_from_disk(wasm_path.join(ZK_CIRCUIT_DIR), &circuit_key)? {
            Some(szk) => Ok(szk),
            None => Err(VmError::zk_err(ZkError::new_err(
                "no circuit found on disk.",
            ))),
        }
    }

    /// Load a verifying key from disk
    /// Returns None if the VK file doesn't exist
    #[cfg(feature = "zk")]
    fn load_circuit_from_disk(
        &self,
        dir: impl Into<PathBuf>,
        checksum: &[u8; 72],
    ) -> VmResult<Option<SerializedCircuitData>> {
        println!("loading circuit from disk;");
        let bytes = load_circuit_from_disk(dir, checksum)?;
        println!("length on disk:{};", bytes.len());
        let body = &bytes[0..bytes.len() - crate::COSMWASM_FOOTER_LENGTH];
        let footer = crate::check_circuit(&bytes)
            .map_err(VmError::zk_err)?
            .to_bytes();
        Ok(Some(SerializedCircuitData::new(body, &footer)))
    }
    /// Remove a VK file from disk if the path exists
    #[cfg(feature = "zk")]
    fn remove_circuit_from_disk(
        &self,
        dir: impl Into<PathBuf>,
        checksum: &[u8; 72],
    ) -> VmResult<()> {
        let path: PathBuf = self.circuit_path(dir, checksum);
        println!("{}", path.to_str().unwrap());

        let circuit_path = path.with_extension("bin");
        println!("{}", circuit_path.to_str().unwrap());

        let path_exists = path.exists();
        let circuit_path_exists = circuit_path.exists();
        if !path_exists && !circuit_path_exists {
            return Err(VmError::cache_err("Circuit file does not exist"));
        }
        if path.exists() {
            println!("removing file");
            std::fs::remove_file(&path)
                .map_err(|e| VmError::cache_err(format!("Error removing VK file: {}", e)))?;
            println!("file removed");
        }

        Ok(())
    }
}

unsafe impl<A, S, Q> Sync for Cache<A, S, Q>
where
    A: BackendApi + 'static,
    S: Storage + 'static,
    Q: Querier + 'static,
{
}

unsafe impl<A, S, Q> Send for Cache<A, S, Q>
where
    A: BackendApi + 'static,
    S: Storage + 'static,
    Q: Querier + 'static,
{
}

/// save stores the wasm code in the given directory and returns an ID for lookup.
/// It will create the directory if it doesn't exist.
/// Saving the same byte code multiple times is allowed.
fn save_wasm_to_disk(dir: impl Into<PathBuf>, wasm: &[u8]) -> VmResult<Checksum> {
    // calculate filename
    let checksum = Checksum::generate(wasm);
    let filename = checksum.to_hex();
    let filepath = dir.into().join(filename).with_extension("wasm");

    // write data to file
    // Since the same filename (a collision resistant hash) cannot be generated from two different byte codes
    // (even if a malicious actor tried), it is safe to override.
    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(filepath)
        .map_err(|e| VmError::cache_err(format!("Error opening Wasm file for writing: {e}")))?;
    file.write_all(wasm)
        .map_err(|e| VmError::cache_err(format!("Error writing Wasm file: {e}")))?;

    Ok(checksum)
}

fn load_circuit_from_disk(dir: impl Into<PathBuf>, checksum: &[u8; 72]) -> VmResult<Vec<u8>> {
    // this requires the directory and file to exist
    // The files previously had no extension, so to allow for a smooth transition,
    // we also try to load the file without the wasm extension.
    let path = dir.into().join(hex::encode(checksum));
    let mut file = File::open(path.with_extension("bin"))
        .or_else(|_| File::open(path))
        .map_err(|_e| VmError::cache_err("vm::cache::Circuit file does not exist"))?;

    let mut zk = Vec::<u8>::new();
    file.read_to_end(&mut zk)
        .map_err(|_e| VmError::cache_err("Error reading Circuit file"))?;
    Ok(zk)
}

fn load_wasm_from_disk(dir: impl Into<PathBuf>, checksum: &Checksum) -> VmResult<Vec<u8>> {
    // this requires the directory and file to exist
    // The files previously had no extension, so to allow for a smooth transition,
    // we also try to load the file without the wasm extension.
    let path = dir.into().join(checksum.to_hex());
    let file = path.with_extension("wasm");
    println!("FILE_OPEN_FROM_DISK: {:#?}", file);
    let mut file = File::open(file)
        .or_else(|_| File::open(path))
        .map_err(|_e| VmError::cache_err("Error opening Wasm file for reading"))?;

    let mut wasm = Vec::<u8>::new();
    file.read_to_end(&mut wasm)
        .map_err(|_e| VmError::cache_err("Error reading Wasm file"))?;
    Ok(wasm)
}

/// Removes the Wasm blob for the given checksum from disk.
///
/// In contrast to the file system cache, the existence of the original
/// code is required. So a non-existent file leads to an error as it
/// indicates a bug.
fn remove_circuit_from_disk(dir: impl Into<PathBuf>, checksum: &[u8; 72]) -> VmResult<()> {
    // the files previously had no extension, so to allow for a smooth transition, we delete both
    let path = dir.into().join(hex::encode(checksum));
    let wasm_path = path.with_extension("bin");

    let path_exists = path.exists();
    let wasm_path_exists = wasm_path.exists();
    if !path_exists && !wasm_path_exists {
        return Err(VmError::cache_err("Wasm file does not exist"));
    }

    if path_exists {
        fs::remove_file(path)
            .map_err(|_e| VmError::cache_err("Error removing Wasm file from disk"))?;
    }

    if wasm_path_exists {
        fs::remove_file(wasm_path)
            .map_err(|_e| VmError::cache_err("Error removing Wasm file from disk"))?;
    }

    Ok(())
}
/// Removes the Wasm blob for the given checksum from disk.
///
/// In contrast to the file system cache, the existence of the original
/// code is required. So a non-existent file leads to an error as it
/// indicates a bug.
fn remove_wasm_from_disk(dir: impl Into<PathBuf>, checksum: &Checksum) -> VmResult<()> {
    // the files previously had no extension, so to allow for a smooth transition, we delete both
    let path = dir.into().join(checksum.to_hex());
    let wasm_path = path.with_extension("wasm");

    let path_exists = path.exists();
    let wasm_path_exists = wasm_path.exists();
    if !path_exists && !wasm_path_exists {
        return Err(VmError::cache_err("Wasm file does not exist"));
    }

    if path_exists {
        fs::remove_file(path)
            .map_err(|_e| VmError::cache_err("Error removing Wasm file from disk"))?;
    }

    if wasm_path_exists {
        fs::remove_file(wasm_path)
            .map_err(|_e| VmError::cache_err("Error removing Wasm file from disk"))?;
    }

    Ok(())
}

/// Write param, cs+vk, and full circuit blobs into a single directory.
/// Used by unit tests that operate on a flat temp dir.
#[cfg(feature = "zk")]
fn save_circuit_to_disk(
    dir: impl Into<PathBuf>,
    c: &[u8],
    cf: CircuitFooter,
) -> VmResult<([[u8; 36]; 2], [u8; 72])> {
    let dir = dir.into();
    save_circuit_parts(&dir, &dir, &dir, c, cf)
}

/// Split `c = [params][cs][vk][footer]` across the three on-disk locations.
#[cfg(feature = "zk")]
fn save_circuit_parts(
    param_dir: &Path,
    vk_dir: &Path,
    circuit_dir: &Path,
    c: &[u8],
    cf: CircuitFooter,
) -> VmResult<([[u8; 36]; 2], [u8; 72])> {
    if c.len() < COSMWASM_FOOTER_LENGTH {
        return Err(VmError::cache_err("circuit too short for footer"));
    }
    let body_end = c.len() - COSMWASM_FOOTER_LENGTH;
    let param_len = cf.param_len as usize;
    if param_len > body_end {
        return Err(VmError::cache_err(format!(
            "param_len {param_len} exceeds circuit body {body_end}"
        )));
    }

    let param_bytes = &c[..param_len];
    let vk_body_bytes = &c[param_len..body_end];

    let param_path = param_dir.join(cf.param_filename()).with_extension("bin");
    let vk_path = vk_dir.join(cf.vk_filename()).with_extension("bin");
    let circuit_path = circuit_dir
        .join(hex::encode(cf.to_circuit_key()))
        .with_extension("bin");

    for (path, bytes) in [
        (param_path, param_bytes),
        (vk_path, vk_body_bytes),
        (circuit_path, c),
    ] {
        if let Some(parent) = path.parent() {
            mkdir_p(parent).map_err(|_e| VmError::cache_err("Error creating circuit dir"))?;
        }
        let mut file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(&path)
            .map_err(|e| {
                VmError::cache_err(format!("Error opening Circuit file for writing: {e}"))
            })?;
        file.write_all(bytes)
            .map_err(|e| VmError::cache_err(format!("Error writing Circuit file: {e}")))?;
    }

    Ok((cf.file_keys(), cf.to_circuit_key()))
}

/// save stores the wasm code in the given directory and returns an ID for lookup.
/// It will create the directory if it doesn't exist.
/// Saving the same byte code multiple times is allowed.
#[cfg(feature = "zk")]
fn save_vk_params_to_disk(dir: impl Into<PathBuf>, p: &[u8]) -> VmResult<Checksum> {
    // calculate filename (checksum bytes)
    let param_checksum = Checksum::generate(p);
    let filepath = dir
        .into()
        .join(&param_checksum.to_hex())
        .with_extension("bin");

    println!("param_filename: {}", param_checksum.to_hex());
    // write data to file
    // Since the same filename (a collision resistant hash) cannot be generated from two different byte codes
    // (even if a malicious actor tried), it is safe to override.
    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(filepath)
        .map_err(|e| VmError::cache_err(format!("Error opening Circuit file for writing: {e}")))?;
    file.write_all(p)
        .map_err(|e| VmError::cache_err(format!("Error writing Circuit file: {e}")))?;

    Ok(param_checksum)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::calls::{call_execute, call_instantiate};
    use crate::instance::GasReport;
    use crate::testing::{mock_backend, mock_env, mock_info, MockApi, MockQuerier, MockStorage};
    use cosmwasm_std::{coins, Empty};
    use sha2::{Digest, Sha256};
    use std::borrow::Cow;
    use std::fs::{create_dir_all, remove_dir_all};
    use tempfile::TempDir;
    use wasm_encoder::ComponentSection;

    const TESTING_GAS_LIMIT: u64 = 500_000_000; // ~0.5ms
    const TESTING_MEMORY_LIMIT: Size = Size::mebi(16);
    const TESTING_OPTIONS: InstanceOptions = InstanceOptions {
        gas_limit: TESTING_GAS_LIMIT,
    };
    const TESTING_MEMORY_CACHE_SIZE: Size = Size::mebi(200);

    static NORICK_CIRCUIT: &[u8] = include_bytes!("../testdata/norick_vk.bin");
    static HACKATOM: &[u8] = include_bytes!("../testdata/hackatom.wasm");
    static IBC_REFLECT: &[u8] = include_bytes!("../testdata/ibc_reflect.wasm");
    static IBC2: &[u8] = include_bytes!("../testdata/ibc2.wasm");
    static EMPTY: &[u8] = include_bytes!("../testdata/empty.wasm");
    // Invalid because it doesn't contain required memory and exports
    static INVALID_CONTRACT_WAT: &str = r#"(module
        (type $t0 (func (param i32) (result i32)))
        (func $add_one (export "add_one") (type $t0) (param $p0 i32) (result i32)
            local.get $p0
            i32.const 1
            i32.add))
    "#;

    fn default_capabilities() -> HashSet<String> {
        HashSet::from([
            "cosmwasm_1_1".to_string(),
            "cosmwasm_1_2".to_string(),
            "cosmwasm_1_3".to_string(),
            "cosmwasm_1_4".to_string(),
            "cosmwasm_1_4".to_string(),
            "cosmwasm_2_0".to_string(),
            "cosmwasm_2_1".to_string(),
            "cosmwasm_2_2".to_string(),
            "iterator".to_string(),
            "staking".to_string(),
            "stargate".to_string(),
            crate::capabilities::CAP_BULK_MEMORY.to_string(),
        ])
    }

    fn make_testing_options() -> (CacheOptions, TempDir) {
        let temp_dir = TempDir::new().unwrap();
        (
            CacheOptions {
                base_dir: temp_dir.path().into(),
                available_capabilities: default_capabilities(),
                memory_cache_size_bytes: TESTING_MEMORY_CACHE_SIZE,
                instance_memory_limit_bytes: TESTING_MEMORY_LIMIT,
            },
            temp_dir,
        )
    }

    fn make_stargate_testing_options() -> (CacheOptions, TempDir) {
        let temp_dir = TempDir::new().unwrap();
        let mut capabilities = default_capabilities();
        capabilities.insert("stargate".into());
        (
            CacheOptions {
                base_dir: temp_dir.path().into(),
                available_capabilities: capabilities,
                memory_cache_size_bytes: TESTING_MEMORY_CACHE_SIZE,
                instance_memory_limit_bytes: TESTING_MEMORY_LIMIT,
            },
            temp_dir,
        )
    }

    fn make_ibc2_testing_options() -> (CacheOptions, TempDir) {
        let temp_dir = TempDir::new().unwrap();
        let mut capabilities = default_capabilities();
        capabilities.insert("ibc2".into());
        (
            CacheOptions {
                base_dir: temp_dir.path().into(),
                available_capabilities: capabilities,
                memory_cache_size_bytes: TESTING_MEMORY_CACHE_SIZE,
                instance_memory_limit_bytes: TESTING_MEMORY_LIMIT,
            },
            temp_dir,
        )
    }

    /// Instantiate HACKATOM and return the post-call gas report.
    /// `get_instance` / compile must not consume metering points (`used_internally == 0` first).
    fn instantiate_hackatom_gas_report(
        cache: &Cache<MockApi, MockStorage, MockQuerier>,
        checksum: &Checksum,
    ) -> GasReport {
        let mut instance = cache
            .get_instance(checksum, mock_backend(&[]), TESTING_OPTIONS)
            .unwrap();
        let before = instance.create_gas_report();
        assert_eq!(before.used_internally, 0);
        assert_eq!(before.used_externally, 0);
        assert_eq!(before.remaining, TESTING_GAS_LIMIT);

        let info = mock_info(&instance.api().addr_make("creator"), &coins(1000, "earth"));
        let verifier = instance.api().addr_make("verifies");
        let beneficiary = instance.api().addr_make("benefits");
        let msg = format!(r#"{{"verifier": "{verifier}", "beneficiary": "{beneficiary}"}}"#);
        let res =
            call_instantiate::<_, _, _, Empty>(&mut instance, &mock_env(), &info, msg.as_bytes())
                .unwrap();
        assert_eq!(res.unwrap().messages.len(), 0);
        instance.create_gas_report()
    }

    /// Takes an instance and executes it
    fn test_hackatom_instance_execution<S, Q>(instance: &mut Instance<MockApi, S, Q>)
    where
        S: Storage + 'static,
        Q: Querier + 'static,
    {
        // instantiate
        let info = mock_info(&instance.api().addr_make("creator"), &coins(1000, "earth"));
        let verifier = instance.api().addr_make("verifies");
        let beneficiary = instance.api().addr_make("benefits");
        let msg = format!(r#"{{"verifier": "{verifier}", "beneficiary": "{beneficiary}"}}"#);
        let response =
            call_instantiate::<_, _, _, Empty>(instance, &mock_env(), &info, msg.as_bytes())
                .unwrap()
                .unwrap();
        assert_eq!(response.messages.len(), 0);

        // execute
        let info = mock_info(&verifier, &coins(15, "earth"));
        let msg = br#"{"release":{"denom":"earth"}}"#;
        let response = call_execute::<_, _, _, Empty>(instance, &mock_env(), &info, msg)
            .unwrap()
            .unwrap();
        assert_eq!(response.messages.len(), 1);
    }

    #[test]
    fn new_base_dir_will_be_created() {
        let temp_dir = TempDir::new().unwrap();
        let my_base_dir = temp_dir.path().join("non-existent-sub-dir");
        let (base_opts, _temp_dir) = make_testing_options();
        let options = CacheOptions {
            base_dir: my_base_dir.clone(),
            ..base_opts
        };
        assert!(!my_base_dir.is_dir());
        let _cache = unsafe { Cache::<MockApi, MockStorage, MockQuerier>::new(options).unwrap() };
        assert!(my_base_dir.is_dir());
    }

    #[test]
    fn store_code_checked_works() {
        let (testing_opts, _temp_dir) = make_testing_options();
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(testing_opts).unwrap() };
        cache.store_code(HACKATOM, true, true).unwrap();
    }

    #[test]
    fn store_code_without_persist_works() {
        let (testing_opts, _temp_dir) = make_testing_options();
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(testing_opts).unwrap() };
        let checksum = cache.store_code(HACKATOM, true, false).unwrap();

        assert!(
            cache.load_wasm(&checksum).is_err(),
            "wasm file should not be saved to disk"
        );
    }

    #[test]
    // This property is required when the same bytecode is uploaded multiple times
    fn store_code_allows_saving_multiple_times() {
        let (testing_opts, _temp_dir) = make_testing_options();
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(testing_opts).unwrap() };
        cache.store_code(HACKATOM, true, true).unwrap();
        cache.store_code(HACKATOM, true, true).unwrap();
    }

    #[test]
    fn store_code_checked_rejects_invalid_contract() {
        let wasm = wat::parse_str(INVALID_CONTRACT_WAT).unwrap();

        let (testing_opts, _temp_dir) = make_testing_options();
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(testing_opts).unwrap() };
        let save_result = cache.store_code(&wasm, true, true);
        match save_result.unwrap_err() {
            VmError::StaticValidationErr { msg, .. } => {
                assert_eq!(msg, "Wasm contract must contain exactly one memory")
            }
            e => panic!("Unexpected error {e:?}"),
        }
    }

    #[test]
    fn store_code_fills_file_system_but_not_memory_cache() {
        // Who knows if and when the uploaded contract will be executed. Don't pollute
        // memory cache before the init call.

        let (testing_opts, _temp_dir) = make_testing_options();
        let cache = unsafe { Cache::new(testing_opts).unwrap() };
        let checksum = cache.store_code(HACKATOM, true, true).unwrap();

        let backend = mock_backend(&[]);
        let _ = cache
            .get_instance(&checksum, backend, TESTING_OPTIONS)
            .unwrap();
        assert_eq!(cache.stats().hits_pinned_memory_cache, 0);
        assert_eq!(cache.stats().hits_memory_cache, 0);
        assert_eq!(cache.stats().hits_fs_cache, 1);
        assert_eq!(cache.stats().misses, 0);
    }

    #[test]
    fn store_code_unchecked_works() {
        let (testing_opts, _temp_dir) = make_testing_options();
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(testing_opts).unwrap() };
        cache.store_code(HACKATOM, false, true).unwrap();
    }

    #[test]
    fn store_code_unchecked_accepts_invalid_contract() {
        let wasm = wat::parse_str(INVALID_CONTRACT_WAT).unwrap();

        let (testing_opts, _temp_dir) = make_testing_options();
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(testing_opts).unwrap() };
        cache.store_code(&wasm, false, true).unwrap();
    }

    #[test]
    fn load_circuit_works() {
        tracing_subscriber::fmt().init();
        let (testing_opts, _temp_dir) = make_testing_options();
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(testing_opts).unwrap() };
        let checksum = cache.store_circuit(NORICK_CIRCUIT, true).unwrap();

        let restored = cache.load_circuit(&checksum).unwrap().unwrap();
        let mut buf = Vec::new();
        buf.extend(restored.vk.to_bytes_with_params().unwrap());
        assert_eq!(buf.as_slice(), NORICK_CIRCUIT);
    }

    #[test]
    fn load_wasm_works() {
        let (testing_opts, _temp_dir) = make_testing_options();
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(testing_opts).unwrap() };
        let checksum = cache.store_code(HACKATOM, true, true).unwrap();

        let restored = cache.load_wasm(&checksum).unwrap();
        assert_eq!(restored, HACKATOM);
    }

    #[test]
    fn load_circuit_works_across_multiple_cache_instances() {
        let tmp_dir = TempDir::new().unwrap();
        let id: [u8; 72];

        {
            let options1 = CacheOptions {
                base_dir: tmp_dir.path().to_path_buf(),
                available_capabilities: default_capabilities(),
                memory_cache_size_bytes: TESTING_MEMORY_CACHE_SIZE,
                instance_memory_limit_bytes: TESTING_MEMORY_LIMIT,
            };
            let cache1: Cache<MockApi, MockStorage, MockQuerier> =
                unsafe { Cache::new(options1).unwrap() };
            id = cache1.store_circuit(NORICK_CIRCUIT, true).unwrap();
        }

        {
            let options2 = CacheOptions {
                base_dir: tmp_dir.path().to_path_buf(),
                available_capabilities: default_capabilities(),
                memory_cache_size_bytes: TESTING_MEMORY_CACHE_SIZE,
                instance_memory_limit_bytes: TESTING_MEMORY_LIMIT,
            };
            let cache2: Cache<MockApi, MockStorage, MockQuerier> =
                unsafe { Cache::new(options2).unwrap() };
            let restored = cache2.load_circuit(&id).unwrap().unwrap();
            let buf = restored.vk.to_bytes_with_params().unwrap();

            if buf.as_slice() != NORICK_CIRCUIT {
                let l = NORICK_CIRCUIT.len();
                let bl = buf.len();
                let res = format!(
                    "(actual_length:{}, buffer length:{}, length_in_cache:{}),(file_checksum:{},buf_checksum:{})",
                    l, bl, restored.size_estimate,Checksum::generate(&NORICK_CIRCUIT).to_hex(),Checksum::generate(&buf).to_hex()
                );
                panic!("{}", res);
            }
        }
    }

    #[test]
    fn load_wasm_works_across_multiple_cache_instances() {
        let tmp_dir = TempDir::new().unwrap();
        let id: Checksum;

        {
            let options1 = CacheOptions {
                base_dir: tmp_dir.path().to_path_buf(),
                available_capabilities: default_capabilities(),
                memory_cache_size_bytes: TESTING_MEMORY_CACHE_SIZE,
                instance_memory_limit_bytes: TESTING_MEMORY_LIMIT,
            };
            let cache1: Cache<MockApi, MockStorage, MockQuerier> =
                unsafe { Cache::new(options1).unwrap() };
            id = cache1.store_code(HACKATOM, true, true).unwrap();
        }

        {
            let options2 = CacheOptions {
                base_dir: tmp_dir.path().to_path_buf(),
                available_capabilities: default_capabilities(),
                memory_cache_size_bytes: TESTING_MEMORY_CACHE_SIZE,
                instance_memory_limit_bytes: TESTING_MEMORY_LIMIT,
            };
            let cache2: Cache<MockApi, MockStorage, MockQuerier> =
                unsafe { Cache::new(options2).unwrap() };
            let restored = cache2.load_wasm(&id).unwrap();
            assert_eq!(restored, HACKATOM);
        }
    }

    #[test]
    fn load_circuit_errors_for_non_existent_id() {
        let (testing_opts, _temp_dir) = make_testing_options();
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(testing_opts).unwrap() };
        let key = [
            5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
            5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
            5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
        ];

        match cache.load_circuit(&key).unwrap_err() {
            VmError::CacheErr { msg, .. } => {
                assert_eq!(msg, "vm::cache::Circuit file does not exist")
            }
            e => panic!("Unexpected error: {e:?}"),
        }
    }
    #[test]
    fn load_wasm_errors_for_non_existent_id() {
        let (testing_opts, _temp_dir) = make_testing_options();
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(testing_opts).unwrap() };
        let checksum = Checksum::from([
            5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
            5, 5, 5,
        ]);

        match cache.load_wasm(&checksum).unwrap_err() {
            VmError::CacheErr { msg, .. } => {
                assert_eq!(msg, "Error opening Wasm file for reading")
            }
            e => panic!("Unexpected error: {e:?}"),
        }
    }

    #[test]
    fn load_circuit_errors_for_corrupted_circuit() {
        let tmp_dir = TempDir::new().unwrap();
        let options = CacheOptions {
            base_dir: tmp_dir.path().to_path_buf(),
            available_capabilities: default_capabilities(),
            memory_cache_size_bytes: TESTING_MEMORY_CACHE_SIZE,
            instance_memory_limit_bytes: TESTING_MEMORY_LIMIT,
        };
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(options.clone()).unwrap() };
        let checksum = cache.store_circuit(NORICK_CIRCUIT, true).unwrap();

        // Corrupt the split + monolithic circuit files on disk
        let state_wasm = tmp_dir.path().join(STATE_DIR).join(WASM_DIR);
        let param_key: [u8; 36] = checksum[..36].try_into().unwrap();
        let vk_key: [u8; 36] = checksum[36..].try_into().unwrap();
        let paths = [
            state_wasm
                .join(ZK_PARAM_DIR)
                .join(hex::encode(param_key))
                .with_extension("bin"),
            state_wasm
                .join(ZK_VK_DIR)
                .join(hex::encode(vk_key))
                .with_extension("bin"),
            state_wasm
                .join(ZK_CIRCUIT_DIR)
                .join(hex::encode(checksum))
                .with_extension("bin"),
        ];
        for filepath in &paths {
            if filepath.exists() {
                let mut file = OpenOptions::new().write(true).open(filepath).unwrap();
                file.write_all(b"broken data").unwrap();
                file.flush().unwrap();
            }
        }

        let res = cache.load_circuit(&checksum);
        match res {
            Ok(cc) => match cc {
                Some(cc) => {
                    // Still served from pinned memory; must not equal the corrupted disk bytes.
                    assert_ne!(cc.vk.to_bytes_with_params().unwrap(), b"broken data");
                }
                None => panic!(
                    "This must succeed, our circuit lives in pinned_memory cache, and can be loaded even if file on disk gets corrupted"
                ),
            },
            Err(_) => panic!(
                "This must succeed, our circuit lives in pinned_memory cache, and can be loaded even if file on disk gets corrupted"
            ),
        };

        // H-04: unpin is pin-only — circuit remains in fs_cache / memory and still loads.
        cache.unpin_circuit(&checksum).unwrap();
        let still = cache
            .load_circuit(&checksum)
            .expect("load after unpin must not err");
        assert!(
            still.is_some(),
            "H-04: after unpin, fs_cache/memory still serves the circuit"
        );

        // Force cold path through corrupted split files: drop process caches by
        // reconstructing Cache over the same base_dir (empty pin/memory LRU),
        // and wipe modules/ so load falls through to state/wasm disk.
        drop(cache);
        let modules_root = tmp_dir.path().join(CACHE_DIR).join(MODULES_DIR);
        if modules_root.exists() {
            let _ = std::fs::remove_dir_all(&modules_root);
        }
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(options).unwrap() };
        let res = cache.load_circuit(&checksum);
        match res {
            Ok(r) => {
                println!("{:#?}", r);
                panic!("This must not succeed — cold path should see corrupted disk")
            }
            Err(e) => {
                println!("{:#?}", e);
                let msg = e.to_string();
                assert!(
                    msg.contains("doesn't match stored hash")
                        || msg.contains("Integrity")
                        || msg.contains("integrity")
                        || msg.contains("bad circuit")
                        || msg.contains("param file length")
                        || msg.contains("vk file length")
                        || msg.contains("Failed to parse")
                        || msg.contains("too short")
                        || msg.contains("deserializ")
                        || msg.contains("circuit file key")
                        || msg.contains("no circuit found"),
                    "unexpected error: {msg}"
                );
            }
        }
    }
    #[test]
    fn load_wasm_errors_for_corrupted_wasm() {
        let tmp_dir = TempDir::new().unwrap();
        let options = CacheOptions {
            base_dir: tmp_dir.path().to_path_buf(),
            available_capabilities: default_capabilities(),
            memory_cache_size_bytes: TESTING_MEMORY_CACHE_SIZE,
            instance_memory_limit_bytes: TESTING_MEMORY_LIMIT,
        };
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(options).unwrap() };
        let checksum = cache.store_code(HACKATOM, true, true).unwrap();

        // Corrupt cache file
        let filepath = tmp_dir
            .path()
            .join(STATE_DIR)
            .join(WASM_DIR)
            .join(checksum.to_hex())
            .with_extension("wasm");
        let mut file = OpenOptions::new().write(true).open(filepath).unwrap();
        file.write_all(b"broken data").unwrap();

        let res = cache.load_wasm(&checksum);
        match res {
            Err(VmError::IntegrityErr { .. }) => {}
            Err(e) => panic!("Unexpected error: {e:?}"),
            Ok(_) => panic!("This must not succeed"),
        }
    }

    #[test]
    fn remove_circuit_works() {
        let (testing_opts, temp_dir) = make_testing_options();
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(testing_opts).unwrap() };

        // Store
        let checksum = cache.store_circuit(NORICK_CIRCUIT, true).unwrap();
        let param_key: [u8; 36] = checksum[..36].try_into().unwrap();
        let vk_key: [u8; 36] = checksum[36..].try_into().unwrap();
        let param_path = temp_dir
            .path()
            .join("state/wasm/zk_param")
            .join(hex::encode(param_key))
            .with_extension("bin");
        let vk_path = temp_dir
            .path()
            .join("state/wasm/zk_vk")
            .join(hex::encode(vk_key))
            .with_extension("bin");
        let circuit_path = temp_dir
            .path()
            .join("state/wasm/zk_circuit")
            .join(hex::encode(checksum))
            .with_extension("bin");
        assert!(param_path.exists());
        assert!(vk_path.exists());
        assert!(circuit_path.exists());

        // Exists
        println!("loading circuit");
        cache.load_circuit(&checksum).unwrap();

        // Remove
        println!("removing circuit");
        cache.remove_circuit(&checksum).unwrap();
        assert!(!param_path.exists());
        assert!(!vk_path.exists());
        assert!(!circuit_path.exists());

        // Does not exist anymore
        println!("ensuring gracful noop on loading non-existent circuit");
        match cache.load_circuit(&checksum).unwrap_err() {
            VmError::CacheErr { msg, .. } => {
                assert!(
                    msg.contains("Circuit file does not exist")
                        || msg.contains("circuit footer unavailable"),
                    "unexpected error: {msg}"
                )
            }
            e => panic!("Unexpected error: {e:?}"),
        };

        // Removing again fails
        match cache.remove_circuit(&checksum).unwrap_err() {
            VmError::CacheErr { msg, .. } => {
                assert_eq!(msg, "Circuit file does not exist")
            }
            e => panic!("Unexpected error: {e:?}"),
        }
    }

    #[test]
    fn remove_wasm_works() {
        let (testing_opts, _temp_dir) = make_testing_options();
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(testing_opts).unwrap() };

        // Store
        let checksum = cache.store_code(HACKATOM, true, true).unwrap();

        // Exists
        cache.load_wasm(&checksum).unwrap();

        // Remove
        cache.remove_wasm(&checksum).unwrap();

        // Does not exist anymore
        match cache.load_wasm(&checksum).unwrap_err() {
            VmError::CacheErr { msg, .. } => {
                assert_eq!(msg, "Error opening Wasm file for reading")
            }
            e => panic!("Unexpected error: {e:?}"),
        }

        // Removing again fails
        match cache.remove_wasm(&checksum).unwrap_err() {
            VmError::CacheErr { msg, .. } => {
                assert_eq!(msg, "Wasm file does not exist")
            }
            e => panic!("Unexpected error: {e:?}"),
        }
    }

    #[test]
    fn get_instance_finds_cached_module() {
        let (testing_opts, _temp_dir) = make_testing_options();
        let cache = unsafe { Cache::new(testing_opts).unwrap() };
        let checksum = cache.store_code(HACKATOM, true, true).unwrap();
        let backend = mock_backend(&[]);
        let _instance = cache
            .get_instance(&checksum, backend, TESTING_OPTIONS)
            .unwrap();
        assert_eq!(cache.stats().hits_pinned_memory_cache, 0);
        assert_eq!(cache.stats().hits_memory_cache, 0);
        assert_eq!(cache.stats().hits_fs_cache, 1);
        assert_eq!(cache.stats().misses, 0);
    }

    #[test]
    fn get_instance_finds_cached_modules_and_stores_to_memory() {
        let (testing_opts, _temp_dir) = make_testing_options();
        let cache = unsafe { Cache::new(testing_opts).unwrap() };
        let checksum = cache.store_code(HACKATOM, true, true).unwrap();
        let backend1 = mock_backend(&[]);
        let backend2 = mock_backend(&[]);
        let backend3 = mock_backend(&[]);
        let backend4 = mock_backend(&[]);
        let backend5 = mock_backend(&[]);

        // from file system
        let _instance1 = cache
            .get_instance(&checksum, backend1, TESTING_OPTIONS)
            .unwrap();
        assert_eq!(cache.stats().hits_pinned_memory_cache, 0);
        assert_eq!(cache.stats().hits_memory_cache, 0);
        assert_eq!(cache.stats().hits_fs_cache, 1);
        assert_eq!(cache.stats().misses, 0);

        // from memory
        let _instance2 = cache
            .get_instance(&checksum, backend2, TESTING_OPTIONS)
            .unwrap();
        assert_eq!(cache.stats().hits_pinned_memory_cache, 0);
        assert_eq!(cache.stats().hits_memory_cache, 1);
        assert_eq!(cache.stats().hits_fs_cache, 1);
        assert_eq!(cache.stats().misses, 0);

        // from memory again
        let _instance3 = cache
            .get_instance(&checksum, backend3, TESTING_OPTIONS)
            .unwrap();
        assert_eq!(cache.stats().hits_pinned_memory_cache, 0);
        assert_eq!(cache.stats().hits_memory_cache, 2);
        assert_eq!(cache.stats().hits_fs_cache, 1);
        assert_eq!(cache.stats().misses, 0);

        // pinning hits the file system cache
        cache.pin(&checksum).unwrap();
        assert_eq!(cache.stats().hits_pinned_memory_cache, 0);
        assert_eq!(cache.stats().hits_memory_cache, 2);
        assert_eq!(cache.stats().hits_fs_cache, 2);
        assert_eq!(cache.stats().misses, 0);

        // from pinned memory cache
        let _instance4 = cache
            .get_instance(&checksum, backend4, TESTING_OPTIONS)
            .unwrap();
        assert_eq!(cache.stats().hits_pinned_memory_cache, 1);
        assert_eq!(cache.stats().hits_memory_cache, 2);
        assert_eq!(cache.stats().hits_fs_cache, 2);
        assert_eq!(cache.stats().misses, 0);

        // from pinned memory cache again
        let _instance5 = cache
            .get_instance(&checksum, backend5, TESTING_OPTIONS)
            .unwrap();
        assert_eq!(cache.stats().hits_pinned_memory_cache, 2);
        assert_eq!(cache.stats().hits_memory_cache, 2);
        assert_eq!(cache.stats().hits_fs_cache, 2);
        assert_eq!(cache.stats().misses, 0);
    }

    #[test]
    fn get_instance_recompiles_module() {
        let (options, _temp_dir) = make_testing_options();
        let cache = unsafe { Cache::new(options.clone()).unwrap() };
        let checksum = cache.store_code(HACKATOM, true, true).unwrap();

        // Remove compiled module from disk
        remove_dir_all(options.base_dir.join(CACHE_DIR).join(MODULES_DIR)).unwrap();

        // The first get_instance recompiles the Wasm (miss)
        let backend = mock_backend(&[]);
        let _instance = cache
            .get_instance(&checksum, backend, TESTING_OPTIONS)
            .unwrap();
        assert_eq!(cache.stats().hits_pinned_memory_cache, 0);
        assert_eq!(cache.stats().hits_memory_cache, 0);
        assert_eq!(cache.stats().hits_fs_cache, 0);
        assert_eq!(cache.stats().misses, 1);

        // The second get_instance finds the module in cache (hit)
        let backend = mock_backend(&[]);
        let _instance = cache
            .get_instance(&checksum, backend, TESTING_OPTIONS)
            .unwrap();
        assert_eq!(cache.stats().hits_pinned_memory_cache, 0);
        assert_eq!(cache.stats().hits_memory_cache, 1);
        assert_eq!(cache.stats().hits_fs_cache, 0);
        assert_eq!(cache.stats().misses, 1);
    }

    #[test]
    fn call_instantiate_on_cached_contract() {
        let (testing_opts, _temp_dir) = make_testing_options();
        let cache = unsafe { Cache::new(testing_opts).unwrap() };
        let checksum = cache.store_code(HACKATOM, true, true).unwrap();

        // from file system
        {
            let mut instance = cache
                .get_instance(&checksum, mock_backend(&[]), TESTING_OPTIONS)
                .unwrap();
            assert_eq!(cache.stats().hits_pinned_memory_cache, 0);
            assert_eq!(cache.stats().hits_memory_cache, 0);
            assert_eq!(cache.stats().hits_fs_cache, 1);
            assert_eq!(cache.stats().misses, 0);

            // instantiate
            let info = mock_info(&instance.api().addr_make("creator"), &coins(1000, "earth"));
            let verifier = instance.api().addr_make("verifies");
            let beneficiary = instance.api().addr_make("benefits");
            let msg = format!(r#"{{"verifier": "{verifier}", "beneficiary": "{beneficiary}"}}"#);
            let res = call_instantiate::<_, _, _, Empty>(
                &mut instance,
                &mock_env(),
                &info,
                msg.as_bytes(),
            )
            .unwrap();
            let msgs = res.unwrap().messages;
            assert_eq!(msgs.len(), 0);
        }

        // from memory
        {
            let mut instance = cache
                .get_instance(&checksum, mock_backend(&[]), TESTING_OPTIONS)
                .unwrap();
            assert_eq!(cache.stats().hits_pinned_memory_cache, 0);
            assert_eq!(cache.stats().hits_memory_cache, 1);
            assert_eq!(cache.stats().hits_fs_cache, 1);
            assert_eq!(cache.stats().misses, 0);

            // instantiate
            let info = mock_info(&instance.api().addr_make("creator"), &coins(1000, "earth"));
            let verifier = instance.api().addr_make("verifies");
            let beneficiary = instance.api().addr_make("benefits");
            let msg = format!(r#"{{"verifier": "{verifier}", "beneficiary": "{beneficiary}"}}"#);
            let res = call_instantiate::<_, _, _, Empty>(
                &mut instance,
                &mock_env(),
                &info,
                msg.as_bytes(),
            )
            .unwrap();
            let msgs = res.unwrap().messages;
            assert_eq!(msgs.len(), 0);
        }

        // from pinned memory
        {
            cache.pin(&checksum).unwrap();

            let mut instance = cache
                .get_instance(&checksum, mock_backend(&[]), TESTING_OPTIONS)
                .unwrap();
            assert_eq!(cache.stats().hits_pinned_memory_cache, 1);
            assert_eq!(cache.stats().hits_memory_cache, 1);
            assert_eq!(cache.stats().hits_fs_cache, 2);
            assert_eq!(cache.stats().misses, 0);

            // instantiate
            let info = mock_info(&instance.api().addr_make("creator"), &coins(1000, "earth"));
            let verifier = instance.api().addr_make("verifies");
            let beneficiary = instance.api().addr_make("benefits");
            let msg = format!(r#"{{"verifier": "{verifier}", "beneficiary": "{beneficiary}"}}"#);
            let res = call_instantiate::<_, _, _, Empty>(
                &mut instance,
                &mock_env(),
                &info,
                msg.as_bytes(),
            )
            .unwrap();
            let msgs = res.unwrap().messages;
            assert_eq!(msgs.len(), 0);
        }
    }

    #[test]
    fn used_internally_is_cache_oblivious() {
        let (options, _temp_dir) = make_testing_options();
        let cache = unsafe { Cache::new(options.clone()).unwrap() };
        let checksum = cache.store_code(HACKATOM, true, true).unwrap();

        // file-system hit (store_code wrote the compiled module)
        let fs_hit = instantiate_hackatom_gas_report(&cache, &checksum);
        assert_eq!(cache.stats().hits_pinned_memory_cache, 0);
        assert_eq!(cache.stats().hits_memory_cache, 0);
        assert_eq!(cache.stats().hits_fs_cache, 1);
        assert_eq!(cache.stats().misses, 0);

        // in-memory LRU hit
        let memory_hit = instantiate_hackatom_gas_report(&cache, &checksum);
        assert_eq!(cache.stats().hits_pinned_memory_cache, 0);
        assert_eq!(cache.stats().hits_memory_cache, 1);
        assert_eq!(cache.stats().hits_fs_cache, 1);
        assert_eq!(cache.stats().misses, 0);

        // pin, then pinned-memory hit
        cache.pin(&checksum).unwrap();
        let pinned_hit = instantiate_hackatom_gas_report(&cache, &checksum);
        assert_eq!(cache.stats().hits_pinned_memory_cache, 1);
        assert_eq!(cache.stats().hits_memory_cache, 1);
        assert_eq!(cache.stats().hits_fs_cache, 2);
        assert_eq!(cache.stats().misses, 0);

        // recompile miss: drop compiled modules, new cache (empty RAM caches)
        remove_dir_all(options.base_dir.join(CACHE_DIR).join(MODULES_DIR)).unwrap();
        let cache = unsafe { Cache::new(options).unwrap() };
        let recompile_miss = instantiate_hackatom_gas_report(&cache, &checksum);
        assert_eq!(cache.stats().hits_pinned_memory_cache, 0);
        assert_eq!(cache.stats().hits_memory_cache, 0);
        assert_eq!(cache.stats().hits_fs_cache, 0);
        assert_eq!(cache.stats().misses, 1);

        println!(
            "used_internally fs_hit={} memory_hit={} pinned_hit={} recompile_miss={}",
            fs_hit.used_internally,
            memory_hit.used_internally,
            pinned_hit.used_internally,
            recompile_miss.used_internally
        );
        println!(
            "used_externally fs_hit={} memory_hit={} pinned_hit={} recompile_miss={}",
            fs_hit.used_externally,
            memory_hit.used_externally,
            pinned_hit.used_externally,
            recompile_miss.used_externally
        );

        assert_eq!(fs_hit.used_internally, memory_hit.used_internally);
        assert_eq!(fs_hit.used_internally, pinned_hit.used_internally);
        assert_eq!(fs_hit.used_internally, recompile_miss.used_internally);
    }

    #[test]
    fn call_execute_on_cached_contract() {
        let (testing_opts, _temp_dir) = make_testing_options();
        let cache = unsafe { Cache::new(testing_opts).unwrap() };
        let checksum = cache.store_code(HACKATOM, true, true).unwrap();

        // from file system
        {
            let mut instance = cache
                .get_instance(&checksum, mock_backend(&[]), TESTING_OPTIONS)
                .unwrap();
            assert_eq!(cache.stats().hits_pinned_memory_cache, 0);
            assert_eq!(cache.stats().hits_memory_cache, 0);
            assert_eq!(cache.stats().hits_fs_cache, 1);
            assert_eq!(cache.stats().misses, 0);

            // instantiate
            let info = mock_info(&instance.api().addr_make("creator"), &coins(1000, "earth"));
            let verifier = instance.api().addr_make("verifies");
            let beneficiary = instance.api().addr_make("benefits");
            let msg = format!(r#"{{"verifier": "{verifier}", "beneficiary": "{beneficiary}"}}"#);
            let response = call_instantiate::<_, _, _, Empty>(
                &mut instance,
                &mock_env(),
                &info,
                msg.as_bytes(),
            )
            .unwrap()
            .unwrap();
            assert_eq!(response.messages.len(), 0);

            // execute
            let info = mock_info(&verifier, &coins(15, "earth"));
            let msg = br#"{"release":{"denom":"earth"}}"#;
            let response = call_execute::<_, _, _, Empty>(&mut instance, &mock_env(), &info, msg)
                .unwrap()
                .unwrap();
            assert_eq!(response.messages.len(), 1);
        }

        // from memory
        {
            let mut instance = cache
                .get_instance(&checksum, mock_backend(&[]), TESTING_OPTIONS)
                .unwrap();
            assert_eq!(cache.stats().hits_pinned_memory_cache, 0);
            assert_eq!(cache.stats().hits_memory_cache, 1);
            assert_eq!(cache.stats().hits_fs_cache, 1);
            assert_eq!(cache.stats().misses, 0);

            // instantiate
            let info = mock_info(&instance.api().addr_make("creator"), &coins(1000, "earth"));
            let verifier = instance.api().addr_make("verifies");
            let beneficiary = instance.api().addr_make("benefits");
            let msg = format!(r#"{{"verifier": "{verifier}", "beneficiary": "{beneficiary}"}}"#);
            let response = call_instantiate::<_, _, _, Empty>(
                &mut instance,
                &mock_env(),
                &info,
                msg.as_bytes(),
            )
            .unwrap()
            .unwrap();
            assert_eq!(response.messages.len(), 0);

            // execute
            let info = mock_info(&verifier, &coins(15, "earth"));
            let msg = br#"{"release":{"denom":"earth"}}"#;
            let response = call_execute::<_, _, _, Empty>(&mut instance, &mock_env(), &info, msg)
                .unwrap()
                .unwrap();
            assert_eq!(response.messages.len(), 1);
        }

        // from pinned memory
        {
            cache.pin(&checksum).unwrap();

            let mut instance = cache
                .get_instance(&checksum, mock_backend(&[]), TESTING_OPTIONS)
                .unwrap();
            assert_eq!(cache.stats().hits_pinned_memory_cache, 1);
            assert_eq!(cache.stats().hits_memory_cache, 1);
            assert_eq!(cache.stats().hits_fs_cache, 2);
            assert_eq!(cache.stats().misses, 0);

            // instantiate
            let info = mock_info(&instance.api().addr_make("creator"), &coins(1000, "earth"));
            let verifier = instance.api().addr_make("verifies");
            let beneficiary = instance.api().addr_make("benefits");
            let msg = format!(r#"{{"verifier": "{verifier}", "beneficiary": "{beneficiary}"}}"#);
            let response = call_instantiate::<_, _, _, Empty>(
                &mut instance,
                &mock_env(),
                &info,
                msg.as_bytes(),
            )
            .unwrap()
            .unwrap();
            assert_eq!(response.messages.len(), 0);

            // execute
            let info = mock_info(&verifier, &coins(15, "earth"));
            let msg = br#"{"release":{"denom":"earth"}}"#;
            let response = call_execute::<_, _, _, Empty>(&mut instance, &mock_env(), &info, msg)
                .unwrap()
                .unwrap();
            assert_eq!(response.messages.len(), 1);
        }
    }

    #[test]
    fn call_execute_on_recompiled_contract() {
        let (options, _temp_dir) = make_testing_options();
        let cache = unsafe { Cache::new(options.clone()).unwrap() };
        let checksum = cache.store_code(HACKATOM, true, true).unwrap();

        // Remove compiled module from disk
        remove_dir_all(options.base_dir.join(CACHE_DIR).join(MODULES_DIR)).unwrap();

        // Recompiles the Wasm (miss on all caches)
        let backend = mock_backend(&[]);
        let mut instance = cache
            .get_instance(&checksum, backend, TESTING_OPTIONS)
            .unwrap();
        assert_eq!(cache.stats().hits_pinned_memory_cache, 0);
        assert_eq!(cache.stats().hits_memory_cache, 0);
        assert_eq!(cache.stats().hits_fs_cache, 0);
        assert_eq!(cache.stats().misses, 1);
        test_hackatom_instance_execution(&mut instance);
    }

    #[test]
    fn use_multiple_cached_instances_of_same_contract() {
        let (testing_opts, _temp_dir) = make_testing_options();
        let cache = unsafe { Cache::new(testing_opts).unwrap() };
        let checksum = cache.store_code(HACKATOM, true, true).unwrap();

        // these differentiate the two instances of the same contract
        let backend1 = mock_backend(&[]);
        let backend2 = mock_backend(&[]);

        // instantiate instance 1
        let mut instance = cache
            .get_instance(&checksum, backend1, TESTING_OPTIONS)
            .unwrap();
        let info = mock_info("owner1", &coins(1000, "earth"));
        let sue = instance.api().addr_make("sue");
        let mary = instance.api().addr_make("mary");
        let msg = format!(r#"{{"verifier": "{sue}", "beneficiary": "{mary}"}}"#);
        let res =
            call_instantiate::<_, _, _, Empty>(&mut instance, &mock_env(), &info, msg.as_bytes())
                .unwrap();
        let msgs = res.unwrap().messages;
        assert_eq!(msgs.len(), 0);
        let backend1 = instance.recycle().unwrap();

        // instantiate instance 2
        let mut instance = cache
            .get_instance(&checksum, backend2, TESTING_OPTIONS)
            .unwrap();
        let info = mock_info("owner2", &coins(500, "earth"));
        let bob = instance.api().addr_make("bob");
        let john = instance.api().addr_make("john");
        let msg = format!(r#"{{"verifier": "{bob}", "beneficiary": "{john}"}}"#);
        let res =
            call_instantiate::<_, _, _, Empty>(&mut instance, &mock_env(), &info, msg.as_bytes())
                .unwrap();
        let msgs = res.unwrap().messages;
        assert_eq!(msgs.len(), 0);
        let backend2 = instance.recycle().unwrap();

        // run contract 2 - just sanity check - results validate in contract unit tests
        let mut instance = cache
            .get_instance(&checksum, backend2, TESTING_OPTIONS)
            .unwrap();
        let info = mock_info(&bob, &coins(15, "earth"));
        let msg = br#"{"release":{"denom":"earth"}}"#;
        let res = call_execute::<_, _, _, Empty>(&mut instance, &mock_env(), &info, msg).unwrap();
        let msgs = res.unwrap().messages;
        assert_eq!(1, msgs.len());

        // run contract 1 - just sanity check - results validate in contract unit tests
        let mut instance = cache
            .get_instance(&checksum, backend1, TESTING_OPTIONS)
            .unwrap();
        let info = mock_info(&sue, &coins(15, "earth"));
        let msg = br#"{"release":{"denom":"earth"}}"#;
        let res = call_execute::<_, _, _, Empty>(&mut instance, &mock_env(), &info, msg).unwrap();
        let msgs = res.unwrap().messages;
        assert_eq!(1, msgs.len());
    }

    #[test]
    fn resets_gas_when_reusing_instance() {
        let (testing_opts, _temp_dir) = make_testing_options();
        let cache = unsafe { Cache::new(testing_opts).unwrap() };
        let checksum = cache.store_code(HACKATOM, true, true).unwrap();

        let backend1 = mock_backend(&[]);
        let backend2 = mock_backend(&[]);

        // Init from module cache
        let mut instance1 = cache
            .get_instance(&checksum, backend1, TESTING_OPTIONS)
            .unwrap();
        assert_eq!(cache.stats().hits_pinned_memory_cache, 0);
        assert_eq!(cache.stats().hits_memory_cache, 0);
        assert_eq!(cache.stats().hits_fs_cache, 1);
        assert_eq!(cache.stats().misses, 0);
        let original_gas = instance1.get_gas_left();

        // Consume some gas
        let info = mock_info("owner1", &coins(1000, "earth"));
        let sue = instance1.api().addr_make("sue");
        let mary = instance1.api().addr_make("mary");
        let msg = format!(r#"{{"verifier": "{sue}", "beneficiary": "{mary}"}}"#);
        call_instantiate::<_, _, _, Empty>(&mut instance1, &mock_env(), &info, msg.as_bytes())
            .unwrap()
            .unwrap();
        assert!(instance1.get_gas_left() < original_gas);

        // Init from memory cache
        let mut instance2 = cache
            .get_instance(&checksum, backend2, TESTING_OPTIONS)
            .unwrap();
        assert_eq!(cache.stats().hits_pinned_memory_cache, 0);
        assert_eq!(cache.stats().hits_memory_cache, 1);
        assert_eq!(cache.stats().hits_fs_cache, 1);
        assert_eq!(cache.stats().misses, 0);
        assert_eq!(instance2.get_gas_left(), TESTING_GAS_LIMIT);
    }

    #[test]
    fn recovers_from_out_of_gas() {
        let (testing_opts, _temp_dir) = make_testing_options();
        let cache = unsafe { Cache::new(testing_opts).unwrap() };
        let checksum = cache.store_code(HACKATOM, true, true).unwrap();

        let backend1 = mock_backend(&[]);
        let backend2 = mock_backend(&[]);

        // Init from module cache
        let options = InstanceOptions { gas_limit: 10 };
        let mut instance1 = cache.get_instance(&checksum, backend1, options).unwrap();
        assert_eq!(cache.stats().hits_fs_cache, 1);
        assert_eq!(cache.stats().misses, 0);

        // Consume some gas. This fails
        let info1 = mock_info("owner1", &coins(1000, "earth"));
        let sue = instance1.api().addr_make("sue");
        let mary = instance1.api().addr_make("mary");
        let msg1 = format!(r#"{{"verifier": "{sue}", "beneficiary": "{mary}"}}"#);

        match call_instantiate::<_, _, _, Empty>(
            &mut instance1,
            &mock_env(),
            &info1,
            msg1.as_bytes(),
        )
        .unwrap_err()
        {
            VmError::GasDepletion { .. } => (), // all good, continue
            e => panic!("unexpected error, {e:?}"),
        }
        assert_eq!(instance1.get_gas_left(), 0);

        // Init from memory cache
        let options = InstanceOptions {
            gas_limit: TESTING_GAS_LIMIT,
        };
        let mut instance2 = cache.get_instance(&checksum, backend2, options).unwrap();
        assert_eq!(cache.stats().hits_pinned_memory_cache, 0);
        assert_eq!(cache.stats().hits_memory_cache, 1);
        assert_eq!(cache.stats().hits_fs_cache, 1);
        assert_eq!(cache.stats().misses, 0);
        assert_eq!(instance2.get_gas_left(), TESTING_GAS_LIMIT);

        // Now it works
        let info2 = mock_info("owner2", &coins(500, "earth"));
        let bob = instance2.api().addr_make("bob");
        let john = instance2.api().addr_make("john");
        let msg2 = format!(r#"{{"verifier": "{bob}", "beneficiary": "{john}"}}"#);
        call_instantiate::<_, _, _, Empty>(&mut instance2, &mock_env(), &info2, msg2.as_bytes())
            .unwrap()
            .unwrap();
    }

    #[test]
    fn save_circuit_to_disk_works_for_same_data_multiple_times() {
        let tmp_dir = TempDir::new().unwrap();
        let path = tmp_dir.path();
        // Store
        let code = NORICK_CIRCUIT;
        let footer = zk_cosmwasm::CircuitFooter::from_bytes(
            &code[code.len() - crate::COSMWASM_FOOTER_LENGTH..],
        )
        .unwrap();

        save_circuit_to_disk(path, &code, footer).unwrap();
        save_circuit_to_disk(path, &code, footer).unwrap();
    }

    #[test]
    fn save_wasm_to_disk_works_for_same_data_multiple_times() {
        let tmp_dir = TempDir::new().unwrap();
        let path = tmp_dir.path();
        let code = vec![12u8; 17];

        save_wasm_to_disk(path, &code).unwrap();
        save_wasm_to_disk(path, &code).unwrap();
    }

    #[test]
    fn save_wasm_to_disk_fails_on_non_existent_dir() {
        let tmp_dir = TempDir::new().unwrap();
        let path = tmp_dir.path().join("something");
        let code = vec![12u8; 17];
        let res = save_wasm_to_disk(path.to_str().unwrap(), &code);
        assert!(res.is_err());
    }

    #[test]
    fn load_circuit_from_disk_works() {
        let tmp_dir = TempDir::new().unwrap();
        let path = tmp_dir.path();
        let code = NORICK_CIRCUIT;
        let footer = zk_cosmwasm::CircuitFooter::from_bytes(
            &code[code.len() - crate::COSMWASM_FOOTER_LENGTH..],
        )
        .unwrap();
        let checksum = save_circuit_to_disk(path, &code, footer).unwrap();

        let loaded = load_circuit_from_disk(path, &checksum.1).unwrap();
        assert_eq!(code, loaded);
    }

    #[test]
    fn load_wasm_from_disk_works() {
        let tmp_dir = TempDir::new().unwrap();
        let path = tmp_dir.path();
        let code = vec![12u8; 17];
        let checksum = save_wasm_to_disk(path, &code).unwrap();

        let loaded = load_wasm_from_disk(path, &checksum).unwrap();
        assert_eq!(code, loaded);
    }

    #[test]
    fn load_wasm_from_disk_works_in_subfolder() {
        let tmp_dir = TempDir::new().unwrap();
        let path = tmp_dir.path().join("something");
        create_dir_all(&path).unwrap();
        let code = vec![12u8; 17];
        let checksum = save_wasm_to_disk(&path, &code).unwrap();

        let loaded = load_wasm_from_disk(&path, &checksum).unwrap();
        assert_eq!(code, loaded);
    }
    #[test]
    fn load_circuit_from_disk_works_in_subfolder() {
        let tmp_dir = TempDir::new().unwrap();
        let path = tmp_dir.path().join("something");
        create_dir_all(&path).unwrap();
        let code = NORICK_CIRCUIT;
        let footer = zk_cosmwasm::CircuitFooter::from_bytes(
            &code[code.len() - crate::COSMWASM_FOOTER_LENGTH..],
        )
        .unwrap();

        let checksum = save_circuit_to_disk(&path, &code, footer).unwrap();

        let loaded = load_circuit_from_disk(&path, &checksum.1).unwrap();
        assert_eq!(code, loaded);
    }

    #[test]
    fn remove_circuit_from_disk_works() {
        let tmp_dir = TempDir::new().unwrap();
        let path = tmp_dir.path();
        let code = NORICK_CIRCUIT;
        let footer = zk_cosmwasm::CircuitFooter::from_bytes(
            &code[code.len() - crate::COSMWASM_FOOTER_LENGTH..],
        )
        .unwrap();
        let checksum = save_circuit_to_disk(path, &code, footer).unwrap();

        remove_circuit_from_disk(path, &checksum.1).unwrap();

        // removing again fails

        match remove_circuit_from_disk(path, &checksum.1).unwrap_err() {
            VmError::CacheErr { msg, .. } => assert_eq!(msg, "Wasm file does not exist"),
            err => panic!("Unexpected error: {err:?}"),
        }
    }
    #[test]
    fn remove_wasm_from_disk_works() {
        let tmp_dir = TempDir::new().unwrap();
        let path = tmp_dir.path();
        let code = vec![12u8; 17];
        let checksum = save_wasm_to_disk(path, &code).unwrap();

        remove_wasm_from_disk(path, &checksum).unwrap();

        // removing again fails

        match remove_wasm_from_disk(path, &checksum).unwrap_err() {
            VmError::CacheErr { msg, .. } => assert_eq!(msg, "Wasm file does not exist"),
            err => panic!("Unexpected error: {err:?}"),
        }
    }

    #[test]
    fn analyze_works() {
        use Entrypoint as E;

        let (testing_opts, _temp_dir) = make_stargate_testing_options();
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(testing_opts).unwrap() };

        let checksum1 = cache.store_code(HACKATOM, true, true).unwrap();
        let report1 = cache.analyze(&checksum1).unwrap();
        assert_eq!(
            report1,
            AnalysisReport {
                has_ibc_entry_points: false,
                entrypoints: BTreeSet::from([
                    E::Instantiate,
                    E::Migrate,
                    E::Sudo,
                    E::Execute,
                    E::Query
                ]),
                required_capabilities: BTreeSet::from([
                    "cosmwasm_1_1".to_string(),
                    "cosmwasm_1_2".to_string(),
                    "cosmwasm_1_3".to_string(),
                    "cosmwasm_1_4".to_string(),
                    "cosmwasm_1_4".to_string(),
                    "cosmwasm_2_0".to_string(),
                    "cosmwasm_2_1".to_string(),
                    "cosmwasm_2_2".to_string(),
                ]),
                contract_migrate_version: Some(420),
            }
        );

        let checksum2 = cache.store_code(IBC_REFLECT, true, true).unwrap();
        let report2 = cache.analyze(&checksum2).unwrap();
        let mut ibc_contract_entrypoints =
            BTreeSet::from([E::Instantiate, E::Migrate, E::Execute, E::Reply, E::Query]);
        ibc_contract_entrypoints.extend(REQUIRED_IBC_EXPORTS);
        assert_eq!(
            report2,
            AnalysisReport {
                has_ibc_entry_points: true,
                entrypoints: ibc_contract_entrypoints,
                required_capabilities: BTreeSet::from_iter([
                    "cosmwasm_1_1".to_string(),
                    "cosmwasm_1_2".to_string(),
                    "cosmwasm_1_3".to_string(),
                    "cosmwasm_1_4".to_string(),
                    "cosmwasm_1_4".to_string(),
                    "cosmwasm_2_0".to_string(),
                    "cosmwasm_2_1".to_string(),
                    "cosmwasm_2_2".to_string(),
                    "iterator".to_string(),
                    "stargate".to_string()
                ]),
                contract_migrate_version: None,
            }
        );

        let checksum3 = cache.store_code(EMPTY, true, true).unwrap();
        let report3 = cache.analyze(&checksum3).unwrap();
        assert_eq!(
            report3,
            AnalysisReport {
                has_ibc_entry_points: false,
                entrypoints: BTreeSet::new(),
                required_capabilities: BTreeSet::from(["iterator".to_string()]),
                contract_migrate_version: None,
            }
        );

        let mut wasm_with_version = EMPTY.to_vec();
        let custom_section = wasm_encoder::CustomSection {
            name: Cow::Borrowed("cw_migrate_version"),
            data: Cow::Borrowed(b"21"),
        };
        custom_section.append_to_component(&mut wasm_with_version);

        let checksum4 = cache.store_code(&wasm_with_version, true, true).unwrap();
        let report4 = cache.analyze(&checksum4).unwrap();
        assert_eq!(
            report4,
            AnalysisReport {
                has_ibc_entry_points: false,
                entrypoints: BTreeSet::new(),
                required_capabilities: BTreeSet::from(["iterator".to_string()]),
                contract_migrate_version: Some(21),
            }
        );

        let (testing_opts, _temp_dir) = make_ibc2_testing_options();
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(testing_opts).unwrap() };
        let checksum5 = cache.store_code(IBC2, true, true).unwrap();
        let report5 = cache.analyze(&checksum5).unwrap();
        let ibc2_contract_entrypoints = BTreeSet::from([
            E::Instantiate,
            E::Query,
            E::Ibc2PacketReceive,
            E::Ibc2PacketTimeout,
            E::Ibc2PacketAck,
            E::Ibc2PacketSend,
        ]);
        assert_eq!(
            report5,
            AnalysisReport {
                has_ibc_entry_points: false,
                entrypoints: ibc2_contract_entrypoints,
                required_capabilities: BTreeSet::from_iter([
                    "iterator".to_string(),
                    "ibc2".to_string()
                ]),
                contract_migrate_version: None,
            }
        );
    }

    #[test]
    fn pinned_metrics_works() {
        let (testing_opts, _temp_dir) = make_testing_options();
        let cache = unsafe { Cache::new(testing_opts).unwrap() };
        let checksum = cache.store_code(HACKATOM, true, true).unwrap();

        cache.pin(&checksum).unwrap();

        let pinned_metrics = cache.pinned_metrics();
        assert_eq!(pinned_metrics.per_module.len(), 1);
        assert_eq!(pinned_metrics.per_module[0].0, CacheKey::Checksum(checksum));
        assert_eq!(pinned_metrics.per_module[0].1.hits, 0);

        let backend = mock_backend(&[]);
        let _ = cache
            .get_instance(&checksum, backend, TESTING_OPTIONS)
            .unwrap();

        let pinned_metrics = cache.pinned_metrics();
        assert_eq!(pinned_metrics.per_module.len(), 1);
        assert_eq!(pinned_metrics.per_module[0].0, CacheKey::Checksum(checksum));
        assert_eq!(pinned_metrics.per_module[0].1.hits, 1);

        let empty_checksum = cache.store_code(EMPTY, true, true).unwrap();
        cache.pin(&empty_checksum).unwrap();

        let pinned_metrics = cache.pinned_metrics();
        assert_eq!(pinned_metrics.per_module.len(), 2);

        let get_module_hits = |checksum| {
            pinned_metrics
                .per_module
                .iter()
                .find(|(iter_checksum, _module)| *iter_checksum == checksum)
                .map(|(_checksum, module)| module)
                .cloned()
                .unwrap()
        };

        assert_eq!(get_module_hits(CacheKey::Checksum(checksum)).hits, 1);
        assert_eq!(get_module_hits(CacheKey::Checksum(empty_checksum)).hits, 0);
    }

    #[test]
    fn pin_unpin_circuit_works() {
        let (testing_opts, _temp_dir) = make_testing_options();
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(testing_opts).unwrap() };
        let circuit_file_key = cache.store_circuit(NORICK_CIRCUIT, true).unwrap();

        println!("pin_circuit for the first time");
        cache.pin_circuit(&circuit_file_key).unwrap();

        println!("pin_circuit for the second time");
        cache.pin_circuit(&circuit_file_key).unwrap();

        cache.unpin_circuit(&circuit_file_key).unwrap();

        // unpin again has no effect
        println!("unpin again has no effect");
        cache.unpin_circuit(&circuit_file_key).unwrap();

        // unpin non existent id has no effect
        let mut non_id = Checksum::generate(b"non_existent").as_slice();

        cache.unpin_circuit(&circuit_file_key).unwrap();
    }

    #[test]
    fn pin_unpin_works() {
        let (testing_opts, _temp_dir) = make_testing_options();
        let cache = unsafe { Cache::new(testing_opts).unwrap() };
        let checksum = cache.store_code(HACKATOM, true, true).unwrap();

        // check not pinned
        let backend = mock_backend(&[]);
        let mut instance = cache
            .get_instance(&checksum, backend, TESTING_OPTIONS)
            .unwrap();
        assert_eq!(cache.stats().hits_pinned_memory_cache, 0);
        assert_eq!(cache.stats().hits_memory_cache, 0);
        assert_eq!(cache.stats().hits_fs_cache, 1);
        assert_eq!(cache.stats().misses, 0);
        test_hackatom_instance_execution(&mut instance);

        // first pin hits file system cache
        cache.pin(&checksum).unwrap();
        assert_eq!(cache.stats().hits_pinned_memory_cache, 0);
        assert_eq!(cache.stats().hits_memory_cache, 0);
        assert_eq!(cache.stats().hits_fs_cache, 2);
        assert_eq!(cache.stats().misses, 0);

        // consecutive pins are no-ops
        cache.pin(&checksum).unwrap();
        assert_eq!(cache.stats().hits_pinned_memory_cache, 0);
        assert_eq!(cache.stats().hits_memory_cache, 0);
        assert_eq!(cache.stats().hits_fs_cache, 2);
        assert_eq!(cache.stats().misses, 0);

        // check pinned
        let backend = mock_backend(&[]);
        let mut instance = cache
            .get_instance(&checksum, backend, TESTING_OPTIONS)
            .unwrap();
        assert_eq!(cache.stats().hits_pinned_memory_cache, 1);
        assert_eq!(cache.stats().hits_memory_cache, 0);
        assert_eq!(cache.stats().hits_fs_cache, 2);
        assert_eq!(cache.stats().misses, 0);
        test_hackatom_instance_execution(&mut instance);

        // unpin
        cache.unpin(&checksum).unwrap();

        // verify unpinned
        let backend = mock_backend(&[]);
        let mut instance = cache
            .get_instance(&checksum, backend, TESTING_OPTIONS)
            .unwrap();
        assert_eq!(cache.stats().hits_pinned_memory_cache, 1);
        assert_eq!(cache.stats().hits_memory_cache, 1);
        assert_eq!(cache.stats().hits_fs_cache, 2);
        assert_eq!(cache.stats().misses, 0);
        test_hackatom_instance_execution(&mut instance);

        // unpin again has no effect
        cache.unpin(&checksum).unwrap();

        // unpin non existent id has no effect
        let non_id = Checksum::generate(b"non_existent");
        cache.unpin(&non_id).unwrap();
    }

    #[test]
    fn pin_recompiles_module() {
        let (options, _temp_dir) = make_testing_options();
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(options.clone()).unwrap() };
        let checksum = cache.store_code(HACKATOM, true, true).unwrap();

        // Remove compiled module from disk
        remove_dir_all(options.base_dir.join(CACHE_DIR).join(MODULES_DIR)).unwrap();

        // Pin misses, forcing a re-compile of the module
        cache.pin(&checksum).unwrap();
        assert_eq!(cache.stats().hits_pinned_memory_cache, 0);
        assert_eq!(cache.stats().hits_memory_cache, 0);
        assert_eq!(cache.stats().hits_fs_cache, 0);
        assert_eq!(cache.stats().misses, 1);

        // After the compilation in pin, the module can be used from pinned memory cache
        let backend = mock_backend(&[]);
        let mut instance = cache
            .get_instance(&checksum, backend, TESTING_OPTIONS)
            .unwrap();
        assert_eq!(cache.stats().hits_pinned_memory_cache, 1);
        assert_eq!(cache.stats().hits_memory_cache, 0);
        assert_eq!(cache.stats().hits_fs_cache, 0);
        assert_eq!(cache.stats().misses, 1);
        test_hackatom_instance_execution(&mut instance);
    }

    #[test]
    fn loading_without_extension_works() {
        let tmp_dir = TempDir::new().unwrap();
        let options = CacheOptions {
            base_dir: tmp_dir.path().to_path_buf(),
            available_capabilities: default_capabilities(),
            memory_cache_size_bytes: TESTING_MEMORY_CACHE_SIZE,
            instance_memory_limit_bytes: TESTING_MEMORY_LIMIT,
        };
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(options).unwrap() };
        let checksum = cache.store_code(HACKATOM, true, true).unwrap();

        // Move the saved wasm to the old path (without extension)
        let old_path = tmp_dir
            .path()
            .join(STATE_DIR)
            .join(WASM_DIR)
            .join(checksum.to_hex());
        let new_path = old_path.with_extension("wasm");
        fs::rename(new_path, old_path).unwrap();

        // loading wasm from before the wasm extension was added should still work
        let restored = cache.load_wasm(&checksum).unwrap();
        assert_eq!(restored, HACKATOM);
    }

    #[test]
    fn func_ref_test() {
        let wasm = wat::parse_str(
            r#"(module
                (type (func))
                (type (func (param funcref)))
                (import "env" "abort" (func $f (type 1)))
                (func (type 0) nop)
                (export "add_one" (func 0))
                (export "allocate" (func 0))
                (export "interface_version_8" (func 0))
                (export "deallocate" (func 0))
                (export "memory" (memory 0))
                (memory 3)
            )"#,
        )
        .unwrap();

        let (testing_opts, _temp_dir) = make_testing_options();
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(testing_opts).unwrap() };

        // making sure this doesn't panic
        let err = cache.store_code(&wasm, true, true).unwrap_err();
        assert!(err.to_string().contains("FuncRef"));
    }

    #[test]
    fn test_wasm_limits_checked() {
        let tmp_dir = TempDir::new().unwrap();

        let config = Config {
            wasm_limits: WasmLimits {
                max_function_params: Some(0),
                ..Default::default()
            },
            cache: CacheOptions {
                base_dir: tmp_dir.path().to_path_buf(),
                available_capabilities: default_capabilities(),
                memory_cache_size_bytes: TESTING_MEMORY_CACHE_SIZE,
                instance_memory_limit_bytes: TESTING_MEMORY_LIMIT,
            },
        };

        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new_with_config(config).unwrap() };
        let err = cache.store_code(HACKATOM, true, true).unwrap_err();
        assert!(matches!(err, VmError::StaticValidationErr { .. }));
    }

    // ── BN254 / empty-param Path A (feature "bn254") ──────────────────────

    /// Build a synthetic BN254 Groth16 circuit blob:
    /// `[vk_body | 80-byte footer]` with `param_len=0`, `cs_len=0`.
    #[cfg(all(feature = "zk", feature = "bn254"))]
    fn synthetic_bn254_circuit(vk_body: &[u8], i: u8) -> (Vec<u8>, CircuitFooter) {
        use sha2::{Digest, Sha256};
        use zk_cosmwasm::{curves::CurveType, CircuitType};

        let param_checksum: [u8; 32] = Sha256::digest([]).into();
        let vk_checksum: [u8; 32] = Sha256::digest(vk_body).into();
        let footer = CircuitFooter::new(
            CircuitType::Groth16,
            CurveType::Bn254,
            0, // k unused
            i,
            0, // param_len
            0, // cs_len
            vk_body.len() as u32,
            param_checksum,
            vk_checksum,
        );
        let mut blob = Vec::with_capacity(vk_body.len() + COSMWASM_FOOTER_LENGTH);
        blob.extend_from_slice(vk_body);
        blob.extend_from_slice(&footer.to_bytes());
        (blob, footer)
    }

    #[test]
    #[cfg(all(feature = "zk", feature = "bn254"))]
    fn bn254_empty_param_store_and_load_roundtrip() {
        let vk_body = b"synthetic-bn254-vk-body-for-cache-phase-a";
        let (blob, footer) = synthetic_bn254_circuit(vk_body, 2);
        assert_eq!(footer.param_len, 0);
        assert_eq!(footer.prover_id, zk_cosmwasm::CircuitType::Groth16 as u8);
        assert_eq!(footer.curve_id, 4);

        let (testing_opts, _temp_dir) = make_testing_options();
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(testing_opts).unwrap() };

        let key = cache.store_circuit(&blob, true).unwrap();
        assert_eq!(key, footer.to_circuit_key());

        let loaded = cache.load_circuit(&key).unwrap().unwrap();
        assert!(
            matches!(loaded.vk, zk_cosmwasm::AnyVerifyingKey::Bn254(_)),
            "expected AnyVerifyingKey::Bn254, got {:?}",
            loaded.vk
        );
        assert_eq!(
            zk_cosmwasm::CircuitType::try_from(loaded.vk.clone()).unwrap(),
            zk_cosmwasm::CircuitType::Groth16
        );
        // Monolithic round-trip: body is vk only (empty params) + footer.
        let restored = loaded.vk.to_bytes_with_params().unwrap();
        assert_eq!(restored.as_slice(), blob.as_slice());

        // Synthetic body is not a real ark VK — verify is a format error (not stub).
        let proof = zk_cosmwasm::Proof::new(vec![0u8; 8]);
        // Instance routing uses curve_id (4), not zkid (D7).
        let inst =
            zk_cosmwasm::AnyInstance::try_from_bytes(loaded.vk.curve_id() as u32, &[]).unwrap();
        let err = loaded.vk.verify(&proof, &[inst]).unwrap_err();
        assert!(
            err.is_format_err()
                || err.to_string().contains("format")
                || err.to_string().contains("invalid"),
            "unexpected verify error: {err}"
        );
    }

    /// Real Groth16 golden through Path A cache store/load/verify.
    #[test]
    #[cfg(all(feature = "zk", feature = "bn254"))]
    fn bn254_golden_store_load_verify() {
        static BLOB: &[u8] = include_bytes!("../../zk/testdata/square_vk.bin");
        static PROOF: &[u8] = include_bytes!("../../zk/testdata/square_proof.bin");
        static PUBLIC: &[u8] = include_bytes!("../../zk/testdata/square_public.bin");

        let (testing_opts, _temp_dir) = make_testing_options();
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(testing_opts).unwrap() };
        let key = cache.store_circuit(BLOB, true).unwrap();
        let loaded = cache.load_circuit(&key).unwrap().unwrap();
        assert_eq!(loaded.vk.curve_id(), 4);
        assert_eq!(loaded.vk.prover_id(), 1);
        let inst =
            zk_cosmwasm::AnyInstance::try_from_bytes(loaded.vk.curve_id() as u32, PUBLIC).unwrap();
        loaded
            .vk
            .verify(&zk_cosmwasm::Proof::new(PROOF.to_vec()), &[inst])
            .expect("golden must verify");
    }

    #[test]
    #[cfg(all(feature = "zk", feature = "bn254"))]
    fn bn254_circuit_loader_hits_pinned_then_memory() {
        let vk_body = b"bn254-loader-warm-path-vk";
        let (blob, footer) = synthetic_bn254_circuit(vk_body, 1);
        let key = footer.to_circuit_key();

        let (testing_opts, _temp_dir) = make_testing_options();
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(testing_opts).unwrap() };

        let stored = cache.store_circuit(&blob, true).unwrap();
        assert_eq!(stored, key);

        // store_circuit(persist=true) pins; first loader call is pinned hit.
        let loader = cache.circuit_loader();
        let vk1 = loader(key).unwrap().expect("pinned load");
        assert!(matches!(vk1, zk_cosmwasm::AnyVerifyingKey::Bn254(_)));
        assert_eq!(cache.stats().hits_pinned_memory_cache, 1);

        // Unpin also clears fs_cache; split files remain under wasm_path.
        // Next load reconstructs from split files and warms memory LRU.
        cache.unpin_circuit(&key).unwrap();
        let vk2 = loader(key).unwrap().expect("cold split reconstruct");
        assert!(matches!(vk2, zk_cosmwasm::AnyVerifyingKey::Bn254(_)));

        // Second load should hit warm memory cache.
        let hits_mem_before = cache.stats().hits_memory_cache;
        let vk3 = loader(key).unwrap().expect("warm memory load");
        assert!(matches!(vk3, zk_cosmwasm::AnyVerifyingKey::Bn254(_)));
        assert!(
            cache.stats().hits_memory_cache > hits_mem_before,
            "second load after reconstruct should hit memory cache"
        );
    }

    #[test]
    #[cfg(all(feature = "zk", feature = "bn254"))]
    fn bn254_store_param_empty_skips_k_header() {
        let (testing_opts, _temp_dir) = make_testing_options();
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(testing_opts).unwrap() };

        // Empty params: must not require Halo2 k header.
        let key = cache.store_param(&[]).unwrap();
        assert_eq!(&key[..4], &0u32.to_le_bytes());
        // SHA256([]) is a fixed digest.
        let empty_hash = Checksum::generate(&[]);
        assert_eq!(&key[4..], empty_hash.as_slice());

        // Footer-derived meta for Groth16+BN254.
        let key2 = cache.store_param_with_meta(&[], 1, 4, 0).unwrap();
        let appstate = u32::from_be_bytes([1, 4, 0, 0]);
        assert_eq!(&key2[..4], &appstate.to_le_bytes());
        assert_eq!(&key2[4..], empty_hash.as_slice());
    }

    #[test]
    #[cfg(feature = "zk")]
    fn halo2_store_circuit_still_uses_nonempty_params() {
        // Regression: no_rick Halo2 path still stores with non-empty params.
        let footer = check_circuit(NORICK_CIRCUIT).unwrap();
        assert!(footer.param_len > 0, "no_rick must have reusable params");
        assert_eq!(footer.prover_id, 0);
        assert_eq!(footer.curve_id, 0);

        let (testing_opts, _temp_dir) = make_testing_options();
        let cache: Cache<MockApi, MockStorage, MockQuerier> =
            unsafe { Cache::new(testing_opts).unwrap() };
        let key = cache.store_circuit(NORICK_CIRCUIT, true).unwrap();
        let loaded = cache.load_circuit(&key).unwrap().unwrap();
        assert!(matches!(loaded.vk, zk_cosmwasm::AnyVerifyingKey::Vesta(_)));
    }
}
