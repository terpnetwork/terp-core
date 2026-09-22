use std::collections::HashSet;

use crate::static_analysis::ExportInfo;

const REQUIRES_PREFIX: &str = "requires_";

/// Host must advertise this to accept rustc ≥ 1.87 modules that emit memory.copy/fill.
/// Detected from opcodes (and from a `requires_bulk_memory` export if present).
pub const CAP_BULK_MEMORY: &str = "bulk_memory";

/// Canonical capability strings for optional multi-curve / algebraic hosts.
///
/// Contracts that need a host export `requires_<capability>` (see
/// [`required_capabilities_from_module`]). Chains pass the intersection of
/// these names (plus core CosmWasm caps) into the wasmvm cache as available
/// capabilities.
///
/// **Honesty:** these names document the *intended* advertisement surface.
/// Enabling a cargo feature on this crate does **not** by itself flip chain
/// genesis flags — operators must still configure wasmd/app available caps.
pub mod multi_curve_caps {
    /// BN254 ECADD / ECMUL / pairing hosts (`feature = "bn254"`).
    pub const BN254: &str = "bn254";
    /// BLAKE2b-256 / BLAKE3-256 hosts (`feature = "hash-blake"`). CPU only.
    pub const HASH_BLAKE: &str = "hash_blake";
    /// Poseidon Pasta + poseidon377 hosts (`feature = "hash-poseidon"`).
    pub const HASH_POSEIDON: &str = "hash_poseidon";
    /// RedPallas / RedJubjub verify hosts (`feature = "redpallas"`).
    pub const REDPALLAS: &str = "redpallas";
    /// Path A Halo2 verify hosts (`feature = "zk"`).
    pub const ZK: &str = "zk";
}

/// Returns capability names enabled by **this** `cosmwasm-vm` build's cargo features.
///
/// Use when assembling the chain's available-capabilities set so guest
/// `requires_*` exports match the linked host imports. Feature-off default
/// returns only `zk` when the default `zk` feature is on (see package features).
///
/// Does **not** claim chain genesis already advertises these — that is an
/// operator / wasmd residual (RH3 docs).
pub fn feature_gated_host_capabilities() -> HashSet<String> {
    let mut set = HashSet::new();
    // This VM always meters rustc memory.copy/fill. Chains that have not
    // upgraded must omit this from available_capabilities so store fails closed.
    set.insert(CAP_BULK_MEMORY.to_string());
    #[cfg(feature = "bn254")]
    {
        set.insert(multi_curve_caps::BN254.to_string());
    }
    #[cfg(feature = "hash-blake")]
    {
        set.insert(multi_curve_caps::HASH_BLAKE.to_string());
    }
    #[cfg(feature = "hash-poseidon")]
    {
        set.insert(multi_curve_caps::HASH_POSEIDON.to_string());
    }
    #[cfg(feature = "redpallas")]
    {
        set.insert(multi_curve_caps::REDPALLAS.to_string());
    }
    #[cfg(feature = "zk")]
    {
        set.insert(multi_curve_caps::ZK.to_string());
    }
    set
}

/// Takes a comma-separated string, splits it by commas, removes empty elements and returns a set of capabilities.
/// This can be used e.g. to initialize the cache.
pub fn capabilities_from_csv(csv: &str) -> HashSet<String> {
    csv.split(',')
        .map(|x| x.trim().to_string())
        .filter(|f| !f.is_empty())
        .collect()
}

/// Implementation for check_wasm, based on static analysis of the bytecode.
/// This is used for code upload, to perform check before compiling the Wasm.
pub fn required_capabilities_including_opcodes(
    module: &crate::parsed_wasm::ParsedWasm<'_>,
) -> HashSet<String> {
    let mut set = required_capabilities_from_module(module);
    if module.uses_metered_bulk_memory {
        set.insert(CAP_BULK_MEMORY.to_string());
    }
    set
}

pub fn required_capabilities_from_module(module: impl ExportInfo) -> HashSet<String> {
    module
        .exported_function_names(Some(REQUIRES_PREFIX))
        .into_iter()
        .filter_map(|name| {
            if name.len() > REQUIRES_PREFIX.len() {
                let (_, required_capability) = name.split_at(REQUIRES_PREFIX.len());
                Some(required_capability.to_string())
            } else {
                None
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use crate::parsed_wasm::ParsedWasm;

    use super::*;

    #[test]
    fn capabilities_from_csv_works() {
        let set = capabilities_from_csv("foo, bar,baz ");
        assert_eq!(set.len(), 3);
        assert!(set.contains("foo"));
        assert!(set.contains("bar"));
        assert!(set.contains("baz"));
    }

    #[test]
    fn feature_gated_host_capabilities_respects_cfg() {
        let set = feature_gated_host_capabilities();
        // Default package features include `zk`; multi-curve stay off unless opted in.
        #[cfg(feature = "zk")]
        assert!(set.contains(multi_curve_caps::ZK));
        #[cfg(not(feature = "bn254"))]
        assert!(!set.contains(multi_curve_caps::BN254));
        #[cfg(not(feature = "hash-blake"))]
        assert!(!set.contains(multi_curve_caps::HASH_BLAKE));
        #[cfg(not(feature = "hash-poseidon"))]
        assert!(!set.contains(multi_curve_caps::HASH_POSEIDON));
        #[cfg(not(feature = "redpallas"))]
        assert!(!set.contains(multi_curve_caps::REDPALLAS));
    }

    #[test]
    fn capabilities_from_csv_skips_empty() {
        let set = capabilities_from_csv("");
        assert_eq!(set.len(), 0);
        let set = capabilities_from_csv("a,,b");
        assert_eq!(set.len(), 2);
        assert!(set.contains("a"));
        assert!(set.contains("b"));
        let set = capabilities_from_csv("a,b,");
        assert_eq!(set.len(), 2);
        assert!(set.contains("a"));
        assert!(set.contains("b"));
    }

    #[test]
    fn required_capabilities_from_module_works() {
        let wasm = wat::parse_str(
            r#"(module
            (type (func))
            (func (type 0) nop)
            (export "requires_water" (func 0))
            (export "requires_" (func 0))
            (export "requires_nutrients" (func 0))
            (export "require_milk" (func 0))
            (export "REQUIRES_air" (func 0))
            (export "requires_sun" (func 0))
            )"#,
        )
        .unwrap();
        let module = ParsedWasm::parse(&wasm).unwrap();

        let required_capabilities = required_capabilities_from_module(&module);
        assert_eq!(required_capabilities.len(), 3);
        assert!(required_capabilities.contains("nutrients"));
        assert!(required_capabilities.contains("sun"));
        assert!(required_capabilities.contains("water"));
    }

    #[test]
    fn required_capabilities_from_module_works_without_exports_section() {
        let wasm = wat::parse_str(r#"(module)"#).unwrap();
        let module = ParsedWasm::parse(&wasm).unwrap();
        let required_capabilities = required_capabilities_from_module(&module);
        assert_eq!(required_capabilities.len(), 0);
    }
}
