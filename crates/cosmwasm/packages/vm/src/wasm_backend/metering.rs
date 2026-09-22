//! # Metering middleware
//!
//! Tracks operator cost and, for bulk-memory ops whose length lives on the
//! Wasm stack, charges `ceil(len / unit_size) * unit_cost` **before** the
//! opcode runs. If remaining gas is insufficient the instance sets the
//! exhausted flag and traps (`unreachable`) without performing the copy/fill.

use crate::parsed_wasm::ParsedWasm;
use std::sync::{Arc, Mutex};
use wasmer::wasmparser::{BlockType, Operator};
use wasmer::{
    ExportIndex, FunctionMiddleware, GlobalInit, GlobalType, LocalFunctionIndex, MiddlewareError,
    MiddlewareReaderState, ModuleMiddleware, Mutability, Type,
};
use wasmer_types::{GlobalIndex, ModuleInfo};

/// Minimum number of local variables in a function
/// that incur charging with additional gas points.
const CHARGED_LOCALS_THRESHOLD: usize = 30;

/// Indexes of Wasm global variables for tracking metering data.
#[derive(Debug, Clone)]
struct MeteringGlobalIndexes(
    /// Remaining gas points.
    GlobalIndex,
    /// Points exhausted flag.
    GlobalIndex,
    /// Data length of bulk-memory operation (saved off the stack, then restored).
    GlobalIndex,
    /// Dynamic cost of bulk-memory operation.
    GlobalIndex,
);

impl MeteringGlobalIndexes {
    fn remaining_points(&self) -> GlobalIndex {
        self.0
    }

    /// `i32` global: 0 remaining, 1 exhausted.
    fn points_exhausted(&self) -> GlobalIndex {
        self.1
    }

    fn data_length(&self) -> GlobalIndex {
        self.2
    }

    fn dynamic_cost(&self) -> GlobalIndex {
        self.3
    }
}

/// Cost of one operator. Linear bulk ops (`memory.copy` / `fill` / `init` /
/// `memory.grow`) set `unit_cost` and `unit_size` so the middleware can charge
/// `ceil(len / unit_size) * unit_cost` from the i32 on the stack **before**
/// the opcode runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MeteringCoefficients {
    pub base: u64,
    pub unit_cost: u64,
    pub unit_size: u64,
}

impl MeteringCoefficients {
    pub const fn flat(base: u64) -> Self {
        Self {
            base,
            unit_cost: 0,
            unit_size: 0,
        }
    }

    pub const fn linear(base: u64, unit_cost: u64, unit_size: u64) -> Self {
        Self {
            base,
            unit_cost,
            unit_size,
        }
    }

    pub const fn is_linear_bulk(self) -> bool {
        self.unit_cost > 0 && self.unit_size > 0
    }
}

/// The module-level metering middleware.
///
/// # Panic
///
/// An instance of `Metering` should _not_ be shared among different
/// modules, since it tracks module-specific information like the
/// global index to store metering state.
pub struct Metering<F: Fn(&Operator) -> MeteringCoefficients + Send + Sync> {
    initial_limit: u64,
    cost_function: Arc<F>,
    global_indexes: Mutex<Option<MeteringGlobalIndexes>>,
    function_locals: Vec<usize>,
}

impl<F: Fn(&Operator) -> MeteringCoefficients + Send + Sync> std::fmt::Debug for Metering<F> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Metering")
            .field("initial_limit", &self.initial_limit)
            .field("cost_function", &"<cost_function>")
            .field("global_indexes", &self.global_indexes)
            .field("function_locals", &self.function_locals)
            .finish()
    }
}

impl<F: Fn(&Operator) -> MeteringCoefficients + Send + Sync> Metering<F> {
    pub fn new(initial_limit: u64, cost_function: F, parsed_wasm: Option<ParsedWasm>) -> Self {
        Self {
            initial_limit,
            cost_function: Arc::new(cost_function),
            global_indexes: Mutex::new(None),
            function_locals: parsed_wasm.map_or_else(Vec::new, |inner| inner.func_locals),
        }
    }
}

impl<F: Fn(&Operator) -> MeteringCoefficients + Send + Sync + 'static> ModuleMiddleware
    for Metering<F>
{
    fn generate_function_middleware(&self, idx: LocalFunctionIndex) -> Box<dyn FunctionMiddleware> {
        let locals_count = self
            .function_locals
            .get(idx.as_u32() as usize)
            .copied()
            .unwrap_or_default();
        Box::new(FunctionMetering {
            is_first_operator: true,
            charged_locals_count: locals_count.saturating_sub(CHARGED_LOCALS_THRESHOLD - 1) as u64,
            cost_function: self.cost_function.clone(),
            global_indexes: self.global_indexes.lock().unwrap().clone().unwrap(),
            accumulated_cost: 0,
        })
    }

    fn transform_module_info(&self, module_info: &mut ModuleInfo) -> Result<(), MiddlewareError> {
        let mut global_indexes = self.global_indexes.lock().unwrap();

        if global_indexes.is_some() {
            panic!("Metering::transform_module_info: Attempting to use a `Metering` middleware from multiple modules.");
        }

        let remaining_points_global_index = module_info
            .globals
            .push(GlobalType::new(Type::I64, Mutability::Var));
        module_info
            .global_initializers
            .push(GlobalInit::I64Const(self.initial_limit as i64));
        module_info.exports.insert(
            "wasmer_metering_remaining_points".to_string(),
            ExportIndex::Global(remaining_points_global_index),
        );

        let points_exhausted_global_index = module_info
            .globals
            .push(GlobalType::new(Type::I32, Mutability::Var));
        module_info
            .global_initializers
            .push(GlobalInit::I32Const(0));
        module_info.exports.insert(
            "wasmer_metering_points_exhausted".to_string(),
            ExportIndex::Global(points_exhausted_global_index),
        );

        let data_length_global_index = module_info
            .globals
            .push(GlobalType::new(Type::I32, Mutability::Var));
        module_info
            .global_initializers
            .push(GlobalInit::I32Const(0));
        // Scratch slots stay off the export map (host ABI is remaining + exhausted only).
        let dynamic_cost_global_index = module_info
            .globals
            .push(GlobalType::new(Type::I64, Mutability::Var));
        module_info
            .global_initializers
            .push(GlobalInit::I64Const(0));

        *global_indexes = Some(MeteringGlobalIndexes(
            remaining_points_global_index,
            points_exhausted_global_index,
            data_length_global_index,
            dynamic_cost_global_index,
        ));

        Ok(())
    }
}

pub struct FunctionMetering<F: Fn(&Operator) -> MeteringCoefficients + Send + Sync> {
    is_first_operator: bool,
    cost_function: Arc<F>,
    global_indexes: MeteringGlobalIndexes,
    accumulated_cost: u64,
    charged_locals_count: u64,
}

impl<F: Fn(&Operator) -> MeteringCoefficients + Send + Sync> std::fmt::Debug
    for FunctionMetering<F>
{
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FunctionMetering")
            .field("is_first_operator", &self.is_first_operator)
            .field("cost_function", &"<cost_function>")
            .field("global_indexes", &self.global_indexes)
            .field("accumulated_cost", &self.accumulated_cost)
            .field("charged_locals_count", &self.charged_locals_count)
            .finish()
    }
}

impl<F: Fn(&Operator) -> MeteringCoefficients + Send + Sync> FunctionMiddleware
    for FunctionMetering<F>
{
    fn feed<'a>(
        &mut self,
        operator: Operator<'a>,
        state: &mut MiddlewareReaderState<'a>,
    ) -> Result<(), MiddlewareError> {
        if self.is_first_operator && self.charged_locals_count > 0 {
            let nop = (self.cost_function)(&Operator::Nop);
            let locals_cost = nop.base.saturating_mul(self.charged_locals_count);
            if is_branching_operator(&operator) {
                self.accumulated_cost += locals_cost;
            } else {
                state.extend(gas_check_branching_wasm_code(
                    &self.global_indexes,
                    locals_cost,
                ));
            }
        }

        let coeffs = (self.cost_function)(&operator);
        self.accumulated_cost = self.accumulated_cost.saturating_add(coeffs.base);

        if is_branching_operator(&operator) && self.accumulated_cost > 0 {
            state.extend(gas_check_branching_wasm_code(
                &self.global_indexes,
                self.accumulated_cost,
            ));
            self.accumulated_cost = 0;
        }

        // Charge bulk-memory by runtime length *before* the opcode.
        if coeffs.is_linear_bulk() {
            state.extend(gas_check_linear_bulk_memory_wasm_code(
                &self.global_indexes,
                coeffs.unit_cost,
                coeffs.unit_size,
                self.accumulated_cost,
            ));
            self.accumulated_cost = 0;
        }

        state.push_operator(operator);
        self.is_first_operator = false;
        Ok(())
    }
}

pub fn is_branching_operator(operator: &Operator) -> bool {
    matches!(
        operator,
        Operator::Loop { .. }
            | Operator::End
            | Operator::If { .. }
            | Operator::Else
            | Operator::Br { .. }
            | Operator::BrTable { .. }
            | Operator::BrIf { .. }
            | Operator::Call { .. }
            | Operator::CallIndirect { .. }
            | Operator::Return
            | Operator::Throw { .. }
            | Operator::ThrowRef
            | Operator::Rethrow { .. }
            | Operator::Delegate { .. }
            | Operator::Catch { .. }
            | Operator::ReturnCall { .. }
            | Operator::ReturnCallIndirect { .. }
            | Operator::BrOnCast { .. }
            | Operator::BrOnCastFail { .. }
            | Operator::CallRef { .. }
            | Operator::ReturnCallRef { .. }
            | Operator::BrOnNull { .. }
            | Operator::BrOnNonNull { .. }
    )
}

fn gas_check_branching_wasm_code<'a>(
    global_indexes: &MeteringGlobalIndexes,
    accumulated_cost: u64,
) -> [Operator<'a>; 12] {
    let idx_remaining_points = global_indexes.remaining_points().as_u32();
    let idx_points_exhausted = global_indexes.points_exhausted().as_u32();
    [
        Operator::GlobalGet {
            global_index: idx_remaining_points,
        },
        Operator::I64Const {
            value: accumulated_cost as i64,
        },
        Operator::I64LtU,
        Operator::If {
            blockty: BlockType::Empty,
        },
        Operator::I32Const { value: 1 },
        Operator::GlobalSet {
            global_index: idx_points_exhausted,
        },
        Operator::Unreachable,
        Operator::End,
        Operator::GlobalGet {
            global_index: idx_remaining_points,
        },
        Operator::I64Const {
            value: accumulated_cost as i64,
        },
        Operator::I64Sub,
        Operator::GlobalSet {
            global_index: idx_remaining_points,
        },
    ]
}

/// Charge linear bulk-memory cost from the i32 length on top of the stack.
/// Restores that length so `memory.copy` / `fill` / `init` still see it.
///
/// `dynamic = ceil(len / unit_size) * unit_cost + accumulated`
/// then if `remaining < dynamic` set exhausted and trap, else subtract.
fn gas_check_linear_bulk_memory_wasm_code<'a>(
    global_indexes: &MeteringGlobalIndexes,
    unit_cost_x: u64,
    unit_size_x: u64,
    accumulated_cost: u64,
) -> [Operator<'a>; 25] {
    let idx_remaining_points = global_indexes.remaining_points().as_u32();
    let idx_points_exhausted = global_indexes.points_exhausted().as_u32();
    let idx_data_length = global_indexes.data_length().as_u32();
    let idx_dynamic_cost = global_indexes.dynamic_cost().as_u32();
    let decremented_unit_size_x = unit_size_x.saturating_sub(1);
    [
        Operator::GlobalSet {
            global_index: idx_data_length,
        },
        Operator::GlobalGet {
            global_index: idx_data_length,
        },
        Operator::I64ExtendI32U,
        Operator::I64Const {
            value: decremented_unit_size_x as i64,
        },
        Operator::I64Add,
        Operator::I64Const {
            value: unit_size_x as i64,
        },
        Operator::I64DivU,
        Operator::I64Const {
            value: unit_cost_x as i64,
        },
        Operator::I64Mul,
        Operator::I64Const {
            value: accumulated_cost as i64,
        },
        Operator::I64Add,
        Operator::GlobalSet {
            global_index: idx_dynamic_cost,
        },
        Operator::GlobalGet {
            global_index: idx_remaining_points,
        },
        Operator::GlobalGet {
            global_index: idx_dynamic_cost,
        },
        Operator::I64LtU,
        Operator::If {
            blockty: BlockType::Empty,
        },
        Operator::I32Const { value: 1 },
        Operator::GlobalSet {
            global_index: idx_points_exhausted,
        },
        Operator::Unreachable,
        Operator::End,
        Operator::GlobalGet {
            global_index: idx_remaining_points,
        },
        Operator::GlobalGet {
            global_index: idx_dynamic_cost,
        },
        Operator::I64Sub,
        Operator::GlobalSet {
            global_index: idx_remaining_points,
        },
        Operator::GlobalGet {
            global_index: idx_data_length,
        },
    ]
}

/// Pure helper used by tests: same ceil-div as the injected Wasm (`(len + unit-1) / unit`).
pub fn linear_bulk_cost(coeffs: MeteringCoefficients, len: u32) -> u64 {
    assert!(coeffs.unit_size > 0);
    let units = (len as u64).saturating_add(coeffs.unit_size - 1) / coeffs.unit_size;
    coeffs
        .base
        .saturating_add(units.saturating_mul(coeffs.unit_cost))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cost(_: &Operator) -> MeteringCoefficients {
        MeteringCoefficients::flat(1)
    }

    #[test]
    fn debug_for_metering_works() {
        assert_eq!(MeteringCoefficients::flat(1), cost(&Operator::Nop));
        assert_eq!(
            "Metering { initial_limit: 0, cost_function: \"<cost_function>\", global_indexes: Mutex { data: None, poisoned: false, .. }, function_locals: [] }",
            format!("{:?}", Metering::new(0, cost, None))
        );
    }

    #[test]
    fn debug_for_function_metering_works() {
        let metering = Metering::new(0, cost, None);
        metering
            .transform_module_info(&mut ModuleInfo::new())
            .unwrap();
        assert_eq!(
            "FunctionMetering { is_first_operator: true, cost_function: \"<cost_function>\", global_indexes: MeteringGlobalIndexes(GlobalIndex(0), GlobalIndex(1), GlobalIndex(2), GlobalIndex(3)), accumulated_cost: 0, charged_locals_count: 0 }",
            format!("{:?}", metering.generate_function_middleware(LocalFunctionIndex::from_u32(0)))
        );
    }

    #[test]
    #[should_panic(
        expected = "Metering::transform_module_info: Attempting to use a `Metering` middleware from multiple modules."
    )]
    fn using_metering_multiple_times_should_panic() {
        let metering = Metering::new(0, cost, None);
        let mut module_1 = ModuleInfo::new();
        let mut module_2 = ModuleInfo::new();
        metering.transform_module_info(&mut module_1).unwrap();
        metering.transform_module_info(&mut module_2).unwrap();
    }

    #[test]
    fn linear_bulk_cost_is_monotone_and_fits_i64() {
        // Matches engine.rs MemoryCopy coefficients.
        let copy = MeteringCoefficients::linear(4_500_000, 50_176, 64);
        assert_eq!(linear_bulk_cost(copy, 0), 4_500_000);
        assert!(linear_bulk_cost(copy, 1) > linear_bulk_cost(copy, 0));
        assert!(linear_bulk_cost(copy, 64) < linear_bulk_cost(copy, 65));
        let max = linear_bulk_cost(copy, u32::MAX);
        assert!(
            max < i64::MAX as u64,
            "dynamic cost must fit i64 for Wasm i64.mul"
        );
        // Huge copy must be far more expensive than a single opcode.
        assert!(max > 1_000_000_000_000);
    }

    #[test]
    fn branching_ops_are_detected() {
        assert!(is_branching_operator(&Operator::Return));
        assert!(is_branching_operator(&Operator::Call { function_index: 0 }));
        assert!(!is_branching_operator(&Operator::I32Const { value: 1 }));
    }
}
