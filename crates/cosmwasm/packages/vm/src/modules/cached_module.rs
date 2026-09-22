use wasmer::{Engine, Module};

/// Some manual tests on Simon's machine showed that Engine is roughly 3-5 KB big,
/// so give it a constant 10 KiB estimate.
#[inline]
pub fn engine_size_estimate() -> usize {
    10 * 1024
}

// NEW: A unified entry type so modules and circuits can share one LRU cache
#[derive(Debug)]
pub enum CacheEntry {
    Module(CachedModule),
    Circuit(CachedCircuit),
    Param(CachedParam),
}

#[derive(Debug, Clone)]
pub struct CachedModule {
    pub module: Module,
    /// The runtime engine to run this module. Ideally we could use a single engine
    /// for all modules but the memory issue described in <https://github.com/wasmerio/wasmer/issues/4377>
    /// requires using one engine per module as a workaround.
    pub engine: Engine,
    /// The estimated size of this element in memory.
    /// Since the cached modules are just [rkyv](https://rkyv.org/) dumps of the Module
    /// instances, we use the file size of the module on disk (not the Wasm!)
    /// as an estimate for this.
    ///
    /// Between CosmWasm 1.4 (Wasmer 4) and 1.5.2, Store/Engine were not cached. This lead to a
    /// memory consumption problem. From 1.5.2 on, Module and Engine are cached and Store is created
    /// from Engine on demand.
    ///
    /// The majority of the Module size is the Artifact which is why we use the module filesize as the estimate.
    /// Some manual tests on Simon's machine showed that Engine is roughly 3-5 KB big, so give it a constant
    /// estimate: [`engine_size_estimate`].
    pub size_estimate: usize,
}

#[derive(Debug, Clone)]
pub struct CachedCircuit {
    pub vk: zk_cosmwasm::AnyVerifyingKey,
    pub size_estimate: usize,
}

#[derive(Debug, Clone)]
pub struct CachedParam {
    /// Raw commitment-parameter bytes (not a verifying key).
    /// Boxed slice: immutable after insert (no Vec capacity waste).
    pub params: Box<[u8]>,
    pub size_estimate: usize,
}

impl CachedParam {
    pub fn from_bytes(params: impl Into<Box<[u8]>>) -> Self {
        let params = params.into();
        let size_estimate = params.len();
        Self {
            params,
            size_estimate,
        }
    }
}
