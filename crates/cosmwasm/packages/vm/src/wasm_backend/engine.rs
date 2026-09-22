use super::Gatekeeper;
use super::LimitingTunables;
use super::{is_branching_operator, Metering};
use crate::parsed_wasm::ParsedWasm;
use crate::size::Size;
use crate::wasm_backend::metering::MeteringCoefficients;
use cosmwasm_vm_derive::hash_function;
use std::sync::Arc;
use wasmer::NativeEngineExt;
use wasmer::{
    sys::BaseTunables, wasmparser::Operator, CompilerConfig, Engine, Pages, Target, WASM_PAGE_SIZE,
};

/// WebAssembly linear memory objects have sizes measured in pages. Each page
/// is 65536 (2^16) bytes. In WebAssembly version 1, a linear memory can have
/// at most 65536 pages, for a total of 2^32 bytes (4 gibibytes).
const MAX_WASM_PAGES: u32 = 65536;

// Hashed into `raw_module_version_discriminator`. Changing this function
// requires bumping MODULE_SERIALIZATION_VERSION.
//
// A flat fee per operator. Target is 1 Teragas per second (see GAS.md).
// Branching/accounting ops inject extra Wasm, so they are ~14× a normal op
// (infinite-loop + argon2 benches in CosmWasm #1042).
// Linear rows for memory.copy/fill/init/grow: CosmWasm develop/v3.1.x #2684.
#[hash_function(const_name = "COST_FUNCTION_HASH")]
fn cost(operator: &Operator) -> MeteringCoefficients {
    const GAS_PER_OPERATION: u64 = 115;
    const BRANCHING_MULTIPLIER: u64 = 14;

    if is_branching_operator(operator) {
        return MeteringCoefficients::flat(GAS_PER_OPERATION * BRANCHING_MULTIPLIER);
    }
    match operator {
        Operator::MemoryInit { .. } => MeteringCoefficients::linear(310_000, 32_768, 64),
        Operator::MemoryGrow { .. } => MeteringCoefficients::linear(2_300_000, 32, 8192),
        Operator::MemoryFill { .. } => MeteringCoefficients::linear(2_900_000, 32_768, 64),
        Operator::MemoryCopy { .. } => MeteringCoefficients::linear(4_500_000, 50_176, 64),
        _ => MeteringCoefficients::flat(GAS_PER_OPERATION),
    }
}

pub fn make_compiler_config() -> impl CompilerConfig + Into<Engine> {
    wasmer::Singlepass::new()
}

pub fn make_runtime_engine(memory_limit: Option<Size>) -> Engine {
    let mut engine = Engine::headless();
    if let Some(limit) = memory_limit {
        let base = BaseTunables::for_target(&Target::default());
        let tunables = LimitingTunables::new(base, limit_to_pages(limit));
        engine.set_tunables(tunables);
    }
    engine
}

pub fn make_compiling_engine(
    memory_limit: Option<Size>,
    parsed_wasm: Option<ParsedWasm>,
) -> Engine {
    let gas_limit = 0;
    let deterministic = Arc::new(Gatekeeper::default());
    let metering = Arc::new(Metering::new(gas_limit, cost, parsed_wasm));

    let mut compiler = make_compiler_config();
    compiler.canonicalize_nans(true);
    compiler.push_middleware(deterministic);
    compiler.push_middleware(metering);
    let mut engine: Engine = compiler.into();
    if let Some(limit) = memory_limit {
        let base = BaseTunables::for_target(&Target::default());
        let tunables = LimitingTunables::new(base, limit_to_pages(limit));
        engine.set_tunables(tunables);
    }
    engine
}

fn limit_to_pages(limit: Size) -> Pages {
    let limit_in_pages: usize = limit.0 / WASM_PAGE_SIZE;

    let capped = match u32::try_from(limit_in_pages) {
        Ok(x) => std::cmp::min(x, MAX_WASM_PAGES),
        Err(_too_large) => MAX_WASM_PAGES,
    };
    Pages(capped)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::capabilities::CAP_BULK_MEMORY;
    use crate::wasm_backend::metering::linear_bulk_cost;
    use wasmer::{imports, Instance, Module, Store, Value};

    fn linear(p: MeteringCoefficients, x: i32) -> u64 {
        if p.unit_size == 0 {
            return p.base;
        }
        (x as u64).div_ceil(p.unit_size) * p.unit_cost + p.base
    }

    fn assert_linear_tables(op: &Operator, base: u64, unit_cost: u64, unit_size: u64) {
        let c = cost(op);
        assert_eq!(c.base, base, "{op:?} base");
        assert_eq!(c.unit_cost, unit_cost, "{op:?} unit_cost");
        assert_eq!(c.unit_size, unit_size, "{op:?} unit_size");
        assert_eq!(linear(c, 0), base);
        assert_eq!(linear(c, i32::MAX), linear_bulk_cost(c, i32::MAX as u32));
        let max = linear_bulk_cost(c, u32::MAX);
        assert!(max < i64::MAX as u64, "{op:?} u32::MAX cost must fit i64");
        assert!(max > base);
    }

    #[test]
    fn cost_works() {
        assert_eq!(cost(&Operator::Br { relative_depth: 3 }).base, 1610);
        assert_eq!(cost(&Operator::Return {}).base, 1610);

        assert_linear_tables(
            &Operator::MemoryInit {
                data_index: 0,
                mem: 0,
            },
            310_000,
            32_768,
            64,
        );

        let m_grow = &Operator::MemoryGrow { mem: 0 };
        assert_eq!(2_300_000, linear(cost(m_grow), 0));
        assert_eq!(2_300_256, linear(cost(m_grow), 65_535));

        assert_linear_tables(&Operator::MemoryFill { mem: 0 }, 2_900_000, 32_768, 64);
        assert_linear_tables(
            &Operator::MemoryCopy {
                src_mem: 0,
                dst_mem: 0,
            },
            4_500_000,
            50_176,
            64,
        );

        // Table ops are not costed — gatekeeper rejects them.
        assert_eq!(
            cost(&Operator::TableCopy {
                src_table: 0,
                dst_table: 0,
            }),
            MeteringCoefficients::flat(115)
        );

        assert_eq!(cost(&Operator::I64Const { value: 7 }).base, 115);
        assert_eq!(cost(&Operator::I64Extend8S {}).base, 115);
    }

    #[test]
    fn make_compiler_config_returns_singlepass() {
        let cc = Box::new(make_compiler_config());
        assert_eq!(cc.compiler().name(), "singlepass");
    }

    #[test]
    fn limit_to_pages_works() {
        assert_eq!(limit_to_pages(Size::new(0)), Pages(0));
        assert_eq!(limit_to_pages(Size::new(1)), Pages(0));
        assert_eq!(limit_to_pages(Size::kibi(63)), Pages(0));
        assert_eq!(limit_to_pages(Size::kibi(64)), Pages(1));
        assert_eq!(limit_to_pages(Size::kibi(65)), Pages(1));
        assert_eq!(limit_to_pages(Size::new(u32::MAX as usize)), Pages(65535));
        assert_eq!(limit_to_pages(Size::gibi(3)), Pages(49152));
        assert_eq!(limit_to_pages(Size::gibi(4)), Pages(65536));
        assert_eq!(limit_to_pages(Size::gibi(5)), Pages(65536));
        assert_eq!(limit_to_pages(Size::new(usize::MAX)), Pages(65536));
    }

    fn copy_module() -> Vec<u8> {
        wat::parse_str(
            r#"
            (module
              (memory (export "memory") 1)
              (func (export "copy") (param $dst i32) (param $src i32) (param $n i32)
                local.get $dst
                local.get $src
                local.get $n
                memory.copy))
            "#,
        )
        .unwrap()
    }

    fn remaining_points(store: &mut Store, instance: &Instance) -> i64 {
        instance
            .exports
            .get_global("wasmer_metering_remaining_points")
            .unwrap()
            .get(store)
            .unwrap_i64()
    }

    fn set_remaining_points(store: &mut Store, instance: &Instance, pts: i64) {
        instance
            .exports
            .get_global("wasmer_metering_remaining_points")
            .unwrap()
            .set(store, Value::I64(pts))
            .unwrap();
        instance
            .exports
            .get_global("wasmer_metering_points_exhausted")
            .unwrap()
            .set(store, Value::I32(0))
            .unwrap();
    }

    fn exhausted(store: &mut Store, instance: &Instance) -> bool {
        instance
            .exports
            .get_global("wasmer_metering_points_exhausted")
            .unwrap()
            .get(store)
            .unwrap_i32()
            == 1
    }

    #[test]
    fn scratch_metering_globals_are_not_exported() {
        let wasm = copy_module();
        let parsed = ParsedWasm::parse(&wasm).unwrap();
        let engine = make_compiling_engine(None, Some(parsed));
        let mut store = Store::new(engine);
        let module = Module::new(&store, &wasm).unwrap();
        let instance = Instance::new(&mut store, &module, &imports! {}).unwrap();
        assert!(instance
            .exports
            .get_global("wasmer_metering_remaining_points")
            .is_ok());
        assert!(instance
            .exports
            .get_global("wasmer_metering_data_length")
            .is_err());
        assert!(instance
            .exports
            .get_global("wasmer_metering_dynamic_cost")
            .is_err());
    }

    #[test]
    fn memory_copy_small_succeeds_and_charges() {
        let wasm = copy_module();
        let parsed = ParsedWasm::parse(&wasm).unwrap();
        assert!(parsed.uses_metered_bulk_memory);
        let engine = make_compiling_engine(None, Some(parsed));
        let mut store = Store::new(engine);
        let module = Module::new(&store, &wasm).unwrap();
        let instance = Instance::new(&mut store, &module, &imports! {}).unwrap();

        instance
            .exports
            .get_memory("memory")
            .unwrap()
            .view(&store)
            .write(0, &[1, 2, 3, 4])
            .unwrap();

        let budget = 20_000_000i64;
        set_remaining_points(&mut store, &instance, budget);
        let copy = instance.exports.get_function("copy").unwrap();
        copy.call(&mut store, &[Value::I32(8), Value::I32(0), Value::I32(4)])
            .unwrap();
        assert!(!exhausted(&mut store, &instance));
        let left = remaining_points(&mut store, &instance);
        assert!(left < budget, "small copy must consume gas (left={left})");
        assert!(left > 0);
        let mut out = [0u8; 4];
        instance
            .exports
            .get_memory("memory")
            .unwrap()
            .view(&store)
            .read(8, &mut out)
            .unwrap();
        assert_eq!(out, [1, 2, 3, 4]);
    }

    #[test]
    fn memory_copy_max_len_exhausts_before_work() {
        let wasm = copy_module();
        let parsed = ParsedWasm::parse(&wasm).unwrap();
        let engine = make_compiling_engine(None, Some(parsed));
        let mut store = Store::new(engine);
        let module = Module::new(&store, &wasm).unwrap();
        let instance = Instance::new(&mut store, &module, &imports! {}).unwrap();

        instance
            .exports
            .get_memory("memory")
            .unwrap()
            .view(&store)
            .write(0, &[0xAA, 0xBB, 0xCC, 0xDD])
            .unwrap();

        set_remaining_points(&mut store, &instance, 50_000_000);
        let copy = instance.exports.get_function("copy").unwrap();
        let err = copy
            .call(
                &mut store,
                &[Value::I32(0), Value::I32(0), Value::I32(i32::MAX)],
            )
            .unwrap_err();
        let msg = format!("{err:?}");
        assert!(
            msg.to_lowercase().contains("unreachable")
                || msg.to_lowercase().contains("out of gas")
                || msg.to_lowercase().contains("exhausted"),
            "expected gas trap, got {msg}"
        );
        assert!(
            exhausted(&mut store, &instance),
            "i32::MAX copy must set exhausted flag before performing the copy"
        );
        let mut still = [0u8; 4];
        instance
            .exports
            .get_memory("memory")
            .unwrap()
            .view(&store)
            .read(0, &mut still)
            .unwrap();
        assert_eq!(
            still,
            [0xAA, 0xBB, 0xCC, 0xDD],
            "copy must not mutate memory after gas trap"
        );
    }

    #[test]
    fn copy_module_requires_bulk_memory_capability() {
        let wasm = copy_module();
        let parsed = ParsedWasm::parse(&wasm).unwrap();
        assert!(parsed.uses_metered_bulk_memory);
        let required = crate::capabilities::required_capabilities_including_opcodes(&parsed);
        assert!(required.contains(CAP_BULK_MEMORY));
    }

    #[test]
    fn rustc_guest_with_memcpy_is_accepted() {
        const RUSTC_GUEST: &[u8] = include_bytes!("../../testdata/bulk_copy_rustc.wasm");
        let parsed = ParsedWasm::parse(RUSTC_GUEST).expect("rustc wasm must parse");
        assert!(
            parsed.uses_metered_bulk_memory,
            "rustc >=1.87 memcpy must emit a metered bulk-memory opcode"
        );
        let required = crate::capabilities::required_capabilities_including_opcodes(&parsed);
        assert!(required.contains(CAP_BULK_MEMORY));
        let engine = make_compiling_engine(None, Some(parsed));
        let store = Store::new(engine);
        Module::new(&store, RUSTC_GUEST).expect("gatekeeper + metering must compile rustc guest");
    }
}
