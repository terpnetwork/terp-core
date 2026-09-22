#[cfg(feature = "bn254")]
use crate::curves::{Bn254Instance, Bn254VerifyingKey};
#[cfg(feature = "halo2-kzg")]
use crate::curves::{Halo2KzgInstance, Halo2KzgVerifyingKey};
use crate::{
    curves::{
        FlockInstance, FlockVerifyingKey, StwoInstance, StwoVerifyingKey, VestaInstance,
        VestaVerifyingKey, VoteInstance, VoteVerifyingKey, ZkCurve,
    },
    CircuitFooter, COSMWASM_FOOTER_LENGTH, ZkError, ZkResult,
};
use halo2_proofs::{
    circuit::Layouter,
    plonk::{self, Circuit, ConstraintSystem},
};
use std::cell::RefCell;

/// A proof of circuit validity.
#[derive(Clone)]
pub struct Proof(pub(crate) Vec<u8>);
impl Proof {
    pub fn new(bytes: Vec<u8>) -> Self {
        Proof(bytes)
    }
    /// CPU-path verify (golden). Optional feature `gpu` may route through
    /// `VerifierBackend` (see docs/research/gpu-accel/DESIGN-G1-verifier-backend.md);
    /// accept/reject must remain bit-identical to this path.
    pub fn verify(&self, vk: &AnyVerifyingKey, i: &[AnyInstance]) -> Result<(), ZkError> {
        vk.verify(&self, i)
    }
}
/// Public inputs.
#[derive(Clone, Debug)]
pub struct CwInstance<C: ZkCurve> {
    pub(crate) i: Vec<C::Scalar>,
    pub(crate) size: usize,
}

/// A verifying key for the zk-wasmvm.
#[derive(Debug, Clone)]
pub struct CwCircuit<C: ZkCurve> {
    /// IPA commitment scheme params
    pub params: C::Params,
    pub vk: C::VerifyingKey,
    pub footer: crate::CircuitFooter,
}

/// The proving key.
#[derive(Debug)]
pub struct CwProvingKey<C: ZkCurve> {
    // pub(crate) params: C::Params,
    pub(crate) _pk: C::ProvingKey,
}

/// A verifying key for the zk-wasmvm.
#[derive(Debug, Clone)]
pub struct CwVerifyingKey<C: ZkCurve> {
    pub(crate) params: C::Params,
    pub vk: C::VerifyingKey,
    pub footer: CircuitFooter,
}

/// The circuit params
#[derive(Debug)]
pub struct CwCircuitParam<C: ZkCurve> {
    pub(crate) params: C::Params,
}

/// The circuit constraint system
#[derive(Debug)]
pub struct CwConstraintSystem<C: ZkCurve> {
    pub(crate) _cs: C::ConstraintSystem,
}

/// A verifying key for any supported curve/circuit.
///
/// Dispatched by `curve_id` from the `CircuitFooter`:
///   0 = Pasta (Vesta)
///   1 = Vote delegation (ZKP #1)
///   2 = Vote commitment (ZKP #2)
///   3 = Share reveal (ZKP #3)
///   4 = BN254 (Groth16)
///
/// Fat Halo2 / Groth16 VKs are **boxed** so pin/LRU `CachedCircuit` slots are
/// not sized to the largest variant (STWO/Flock footers stay inline).
#[derive(Debug, Clone)]
pub enum AnyVerifyingKey {
    Vesta(Box<VestaVerifyingKey>),
    Vote(Box<VoteVerifyingKey>),
    #[cfg(feature = "bn254")]
    Bn254(Box<Bn254VerifyingKey>),
    Stwo(StwoVerifyingKey),
    Flock(FlockVerifyingKey),
    #[cfg(feature = "halo2-kzg")]
    Halo2Kzg(Box<Halo2KzgVerifyingKey>),
}

impl TryFrom<&[u8]> for AnyVerifyingKey {
    type Error = ZkError;
    /// try_from for AnyVerifyingKey expects the bytes to contain:
    /// [0..param.len()] - circuit constraint system parameter bytes
    /// [cs_param..cs_len()] - constraint system
    /// [..bytes.len()-COSMWASM_FOOTER] - verifying key bytes
    /// [bytes.len()-COSMWASM_FOOTER..] -
    fn try_from(bytes: &[u8]) -> Result<Self, Self::Error> {
        if bytes.len() < COSMWASM_FOOTER_LENGTH {
            return Err(ZkError::new_err("Data too short for footer"));
        }

        let footer =
            crate::CircuitFooter::from_bytes(&bytes[bytes.len() - COSMWASM_FOOTER_LENGTH..])?;

        // Dispatch on curve_id as the sole routing key.
        // curve_id is self-describing — each distinct circuit/curve has its own ID.
        match footer.curve_id {
            0 => Ok(AnyVerifyingKey::Vesta(Box::new(
                VestaVerifyingKey::try_from(bytes)?,
            ))),
            1 | 2 | 3 => Ok(AnyVerifyingKey::Vote(Box::new(VoteVerifyingKey::try_from(
                bytes,
            )?))),
            #[cfg(feature = "bn254")]
            4 => Ok(AnyVerifyingKey::Bn254(Box::new(
                Bn254VerifyingKey::try_from(bytes)?,
            ))),
            5 => Ok(AnyVerifyingKey::Stwo(StwoVerifyingKey::try_from(bytes)?)),
            7 => Ok(AnyVerifyingKey::Flock(FlockVerifyingKey::try_from(bytes)?)),
            #[cfg(feature = "halo2-kzg")]
            6 => Ok(AnyVerifyingKey::Halo2Kzg(Box::new(
                Halo2KzgVerifyingKey::try_from(bytes)?,
            ))),
            _ => Err(ZkError::UnsupportedCurve(footer.appstate_key())),
        }
    }
}

impl AnyVerifyingKey {
    /// Footer `curve_id` used for instance dispatch (independent of app `zkid`).
    pub fn curve_id(&self) -> u8 {
        match self {
            AnyVerifyingKey::Vesta(vk) => vk.footer.curve_id,
            AnyVerifyingKey::Vote(vk) => vk.footer.curve_id,
            AnyVerifyingKey::Stwo(vk) => vk.footer.curve_id,
            AnyVerifyingKey::Flock(vk) => vk.footer.curve_id,
            #[cfg(feature = "halo2-kzg")]
            AnyVerifyingKey::Halo2Kzg(vk) => vk.footer.curve_id,
            #[cfg(feature = "bn254")]
            AnyVerifyingKey::Bn254(vk) => vk.footer.curve_id,
        }
    }

    /// Footer `prover_id` (`CircuitType`).
    pub fn prover_id(&self) -> u8 {
        match self {
            AnyVerifyingKey::Vesta(vk) => vk.footer.prover_id,
            AnyVerifyingKey::Vote(vk) => vk.footer.prover_id,
            AnyVerifyingKey::Stwo(vk) => vk.footer.prover_id,
            AnyVerifyingKey::Flock(vk) => vk.footer.prover_id,
            #[cfg(feature = "halo2-kzg")]
            AnyVerifyingKey::Halo2Kzg(vk) => vk.footer.prover_id,
            #[cfg(feature = "bn254")]
            AnyVerifyingKey::Bn254(vk) => vk.footer.prover_id,
        }
    }

    /// Expected public-input count from footer (`i`).
    pub fn public_input_count(&self) -> u8 {
        match self {
            AnyVerifyingKey::Vesta(vk) => vk.footer.i,
            AnyVerifyingKey::Vote(vk) => vk.footer.i,
            AnyVerifyingKey::Stwo(vk) => vk.footer.i,
            AnyVerifyingKey::Flock(vk) => vk.footer.i,
            #[cfg(feature = "halo2-kzg")]
            AnyVerifyingKey::Halo2Kzg(vk) => vk.footer.i,
            #[cfg(feature = "bn254")]
            AnyVerifyingKey::Bn254(vk) => vk.footer.i,
        }
    }

    /// Path A identity: `footer.to_circuit_key()` (72 B). Used to re-bind cold
    /// loads to `CircuitInfo.circuit_key` (H-06).
    pub fn circuit_key(&self) -> [u8; 72] {
        match self {
            AnyVerifyingKey::Vesta(vk) => vk.footer.to_circuit_key(),
            AnyVerifyingKey::Vote(vk) => vk.footer.to_circuit_key(),
            AnyVerifyingKey::Stwo(vk) => vk.footer.to_circuit_key(),
            AnyVerifyingKey::Flock(vk) => vk.footer.to_circuit_key(),
            #[cfg(feature = "halo2-kzg")]
            AnyVerifyingKey::Halo2Kzg(vk) => vk.footer.to_circuit_key(),
            #[cfg(feature = "bn254")]
            AnyVerifyingKey::Bn254(vk) => vk.footer.to_circuit_key(),
        }
    }

    /// Footer layout fields for metadata binding (H-05).
    pub fn footer(&self) -> &crate::CircuitFooter {
        match self {
            AnyVerifyingKey::Vesta(vk) => &vk.footer,
            AnyVerifyingKey::Vote(vk) => &vk.footer,
            AnyVerifyingKey::Stwo(vk) => &vk.footer,
            AnyVerifyingKey::Flock(vk) => &vk.footer,
            #[cfg(feature = "halo2-kzg")]
            AnyVerifyingKey::Halo2Kzg(vk) => &vk.footer,
            #[cfg(feature = "bn254")]
            AnyVerifyingKey::Bn254(vk) => &vk.footer,
        }
    }

    pub fn to_bytes_with_params(&self) -> crate::ZkResult<Vec<u8>> {
        match self {
            AnyVerifyingKey::Vesta(vk) => Ok(vk.to_bytes_with_params()?),
            AnyVerifyingKey::Vote(vk) => {
                let mut bytes = vk.params_bytes.clone();
                bytes.extend_from_slice(&vk.vk_body_bytes);
                bytes.extend_from_slice(&vk.footer.to_bytes());
                Ok(bytes)
            }
            AnyVerifyingKey::Stwo(vk) => Ok(vk.to_blob()),
            AnyVerifyingKey::Flock(vk) => Ok(vk.to_blob()),
            #[cfg(feature = "halo2-kzg")]
            AnyVerifyingKey::Halo2Kzg(vk) => Ok(vk.to_bytes_with_params()?),
            #[cfg(feature = "bn254")]
            AnyVerifyingKey::Bn254(vk) => {
                let mut bytes = vk.vk_bytes.clone();
                bytes.extend_from_slice(&vk.footer.to_bytes());
                Ok(bytes)
            }
        }
    }
    pub fn from_bytes(bytes: &[u8]) -> crate::ZkResult<Self> {
        let footer =
            crate::CircuitFooter::from_bytes(&bytes[bytes.len() - COSMWASM_FOOTER_LENGTH..])?;
        match footer.curve_id {
            0 => Ok(AnyVerifyingKey::Vesta(Box::new(
                VestaVerifyingKey::from_bytes_with_params(bytes)?,
            ))),
            1 | 2 | 3 => Ok(AnyVerifyingKey::Vote(Box::new(VoteVerifyingKey::try_from(
                bytes,
            )?))),
            #[cfg(feature = "bn254")]
            4 => Ok(AnyVerifyingKey::Bn254(Box::new(
                Bn254VerifyingKey::try_from(bytes)?,
            ))),
            5 => Ok(AnyVerifyingKey::Stwo(StwoVerifyingKey::try_from(bytes)?)),
            7 => Ok(AnyVerifyingKey::Flock(FlockVerifyingKey::try_from(bytes)?)),
            #[cfg(feature = "halo2-kzg")]
            6 => Ok(AnyVerifyingKey::Halo2Kzg(Box::new(
                Halo2KzgVerifyingKey::try_from(bytes)?,
            ))),
            _ => Err(ZkError::UnsupportedCurve(footer.appstate_key())),
        }
    }

    pub fn verify(&self, proof: &Proof, i: &[AnyInstance]) -> crate::ZkResult<()> {
        // C-06: crypto-false → VerifyFailed so host Path A returns Ok(1);
        // format/deserial errors stay FormatErr / other (VmError).
        match (self, i) {
            (AnyVerifyingKey::Vesta(vk), [AnyInstance::Vesta(i), ..]) => vk
                .verify(proof, std::slice::from_ref(i))
                .map_err(|_plonk| ZkError::VerifyFailed),
            (AnyVerifyingKey::Vote(vk), [AnyInstance::Vote(i), ..]) => {
                let scalars = i.to_scalars();
                // Fail closed if any PI limb failed to decode (do not silently drop).
                if scalars.len() != i.public_inputs.len() {
                    return Err(ZkError::InvalidScalar);
                }
                match vk.verify(&proof.0, &scalars) {
                    Ok(()) => Ok(()),
                    // Vote verify maps deserial failures as Aborted/new_err and
                    // proof false as "proof verification failed: …".
                    Err(e) if e.is_verify_failed() => Err(e),
                    Err(e) => {
                        let msg = e.to_string();
                        if msg.contains("proof verification failed") {
                            Err(ZkError::VerifyFailed)
                        } else {
                            // Deserial / format paths use FormatErr when possible.
                            Err(ZkError::format_err(msg))
                        }
                    }
                }
            }
            #[cfg(feature = "bn254")]
            (AnyVerifyingKey::Bn254(vk), [AnyInstance::Bn254(i), ..]) => {
                vk.verify(proof, std::slice::from_ref(i))
            }
            (AnyVerifyingKey::Stwo(vk), [AnyInstance::Stwo(i), ..]) => vk.verify(proof, i),
            (AnyVerifyingKey::Flock(vk), [AnyInstance::Flock(i), ..]) => vk.verify(proof, i),
            #[cfg(feature = "halo2-kzg")]
            (AnyVerifyingKey::Halo2Kzg(vk), [AnyInstance::Halo2Kzg(i), ..]) => vk.verify(proof, i),
            _ => Err(ZkError::CurveMismatch),
        }
    }

    /// Reconstruct from separate param and (cs+vk) byte slices, using the
    /// footer to identify the curve and validate the split boundaries.
    /// This is the primary entry point used when loading from separate param/vk files.
    pub fn from_split_bytes(
        param_bytes: &[u8],
        vk_body_bytes: &[u8],
        footer: &CircuitFooter,
    ) -> crate::ZkResult<Self> {
        match footer.curve_id {
            0 => Ok(AnyVerifyingKey::Vesta(Box::new(
                crate::curves::VestaVerifyingKey::from_split_bytes(
                    param_bytes,
                    vk_body_bytes,
                    *footer,
                )?,
            ))),
            1 | 2 | 3 => {
                let mut serialized = Vec::new();
                serialized.extend_from_slice(param_bytes);
                serialized.extend_from_slice(vk_body_bytes);
                serialized.extend_from_slice(&footer.to_bytes());
                Ok(AnyVerifyingKey::Vote(Box::new(VoteVerifyingKey::try_from(
                    serialized.as_slice(),
                )?)))
            }
            #[cfg(feature = "bn254")]
            4 => Ok(AnyVerifyingKey::Bn254(Box::new(
                Bn254VerifyingKey::from_split_bytes(param_bytes, vk_body_bytes, *footer)?,
            ))),
            5 => Ok(AnyVerifyingKey::Stwo(StwoVerifyingKey::from_split_bytes(
                param_bytes,
                vk_body_bytes,
                *footer,
            )?)),
            7 => Ok(AnyVerifyingKey::Flock(FlockVerifyingKey::from_split_bytes(
                param_bytes,
                vk_body_bytes,
                *footer,
            )?)),
            #[cfg(feature = "halo2-kzg")]
            6 => Ok(AnyVerifyingKey::Halo2Kzg(Box::new(
                Halo2KzgVerifyingKey::from_split_bytes(param_bytes, vk_body_bytes, *footer)?,
            ))),
            _ => Err(ZkError::UnsupportedCurve(footer.appstate_key())),
        }
    }
}

/// Public inputs for any supported curve/circuit.
pub enum AnyInstance {
    Vesta(crate::curves::VestaInstance),
    Vote(VoteInstance),
    #[cfg(feature = "bn254")]
    Bn254(crate::curves::Bn254Instance),
    Stwo(StwoInstance),
    Flock(FlockInstance),
    #[cfg(feature = "halo2-kzg")]
    Halo2Kzg(Halo2KzgInstance),
}

/// Circuit proving-system identifier for footer `prover_id`.
///
/// | Value | Variant   | Typical curves / circuits        |
/// |-------|-----------|----------------------------------|
/// | 0     | Plonkish  | Pasta Halo2 (Vesta / vote suite) |
/// | 1     | Groth16   | BN254 (circom / ark-groth16)     |
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
#[repr(u8)]
pub enum CircuitType {
    #[default]
    Plonkish = 0,
    /// Non-Plonkish proving system (Groth16 / BN254).
    Groth16 = 1,
    /// StarkWare S-two / Circle STARK (M31). Never generic Stark.
    Stwo = 2,
    /// Flock hash-based SNARK (BLAKE3 batches).
    Flock = 3,
}

impl CircuitType {
    /// Parse a footer `prover_id` byte into a known circuit type.
    pub fn from_u8(value: u8) -> Option<Self> {
        match value {
            0 => Some(Self::Plonkish),
            1 => Some(Self::Groth16),
            2 => Some(Self::Stwo),
            3 => Some(Self::Flock),
            _ => None,
        }
    }
}

impl TryFrom<AnyVerifyingKey> for CircuitType {
    type Error = ZkError;

    fn try_from(value: AnyVerifyingKey) -> Result<Self, Self::Error> {
        match value {
            AnyVerifyingKey::Vesta(_) => Ok(CircuitType::Plonkish),
            AnyVerifyingKey::Vote(_) => Ok(CircuitType::Plonkish),
            #[cfg(feature = "bn254")]
            AnyVerifyingKey::Bn254(_) => Ok(CircuitType::Groth16),
            AnyVerifyingKey::Stwo(_) => Ok(CircuitType::Stwo),
            AnyVerifyingKey::Flock(_) => Ok(CircuitType::Flock),
            #[cfg(feature = "halo2-kzg")]
            AnyVerifyingKey::Halo2Kzg(_) => Ok(CircuitType::Plonkish),
        }
    }
}

impl TryFrom<u8> for CircuitType {
    type Error = ZkError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        Self::from_u8(value).ok_or_else(|| ZkError::new_err("bad CircuitType"))
    }
}

impl Into<u8> for CircuitType {
    fn into(self) -> u8 {
        match self {
            CircuitType::Plonkish => 0,
            CircuitType::Groth16 => 1,
            CircuitType::Stwo => 2,
            CircuitType::Flock => 3,
        }
    }
}

impl AnyInstance {
    /// Decode public inputs for a **curve_id** (footer field), not app `zkid`.
    ///
    /// Host Path A must pass `vk.curve_id()` here so zkid can be any app id
    /// (e.g. 42) while BN254 still routes to Fr-limb parsing.
    pub fn try_from_bytes(curve_id: impl Into<u32>, bytes: &[u8]) -> ZkResult<Self> {
        match curve_id.into() {
            0u32 => Ok(AnyInstance::Vesta(VestaInstance::try_from(bytes)?)),
            1u32 | 2u32 | 3u32 => Ok(AnyInstance::Vote(VoteInstance::from_bytes(bytes)?)),
            #[cfg(feature = "bn254")]
            4u32 => Ok(AnyInstance::Bn254(Bn254Instance::from_bytes(bytes)?)),
            5u32 => Ok(AnyInstance::Stwo(StwoInstance {
                bytes: bytes.to_vec(),
            })),
            7u32 => Ok(AnyInstance::Flock(FlockInstance {
                bytes: bytes.to_vec(),
            })),
            #[cfg(feature = "halo2-kzg")]
            6u32 => Ok(AnyInstance::Halo2Kzg(Halo2KzgInstance::from_bytes(bytes)?)),
            _ => Err(ZkError::CurveMismatch),
        }
    }
}

/// Custom section name for embedded verifying keys
/// Contracts can embed their VK in a WASM custom section with this name
pub const VK_CUSTOM_SECTION_NAME: &str = "cosmwasm_zk_vk";

#[derive(Debug, Clone)]
pub struct CsBlueprint {
    pub num_fixed_columns: u8,
    pub num_advice_columns: u8,
    pub num_instance_columns: u8,
    pub num_selectors: u32,
    pub permutation_columns: Vec<plonk::Column<plonk::Any>>,
}

impl CsBlueprint {
    /// Fail closed if a column count does not fit the stored widths (`u8` / `u32`).
    pub fn from_cs<F: halo2_proofs::arithmetic::Field>(
        cs: &plonk::ConstraintSystem<F>,
    ) -> ZkResult<Self> {
        fn u8_count(n: usize, what: &str) -> ZkResult<u8> {
            u8::try_from(n).map_err(|_| {
                ZkError::format_err(format!("{what} count {n} exceeds u8 (255)"))
            })
        }
        Ok(Self {
            num_fixed_columns: u8_count(cs.num_fixed_columns(), "fixed")?,
            num_advice_columns: u8_count(cs.num_advice_columns(), "advice")?,
            num_instance_columns: u8_count(cs.num_instance_columns(), "instance")?,
            num_selectors: u32::try_from(cs.num_selectors()).map_err(|_| {
                ZkError::format_err(format!(
                    "selector count {} exceeds u32",
                    cs.num_selectors()
                ))
            })?,
            permutation_columns: cs.permutation_columns(),
        })
    }
}

#[derive(Clone, Debug)]
pub struct SerializedCircuitData {
    pub body: Vec<u8>,
    pub footer: Vec<u8>,
}

impl SerializedCircuitData {
    pub fn new(body: &[u8], footer: &[u8]) -> Self {
        Self {
            body: body.to_vec(),
            footer: footer.to_vec(),
        }
    }
    pub fn serialized_to_vec(&self) -> Vec<u8> {
        let mut buf = Vec::new();
        buf.extend_from_slice(&self.body);
        buf.extend_from_slice(&self.footer);
        buf
    }
}

thread_local! {
    static CS_BLUEPRINT: RefCell<Option<CsBlueprint>> = RefCell::new(None);
}

// // / RAII Guard for DynamicCircuit thread-local configuration.
// // /
// // / Automatically clears the thread-local config when dropped, preventing leaks
// // / and reentrancy issues in concurrent scenarios.
#[must_use = "guard should be held for the entire operation"]
pub struct CsBlueprintGuard;

impl CsBlueprintGuard {
    pub fn install(blueprint: CsBlueprint) -> Self {
        println!("cw::vm::zk::cs_blueprint::install::{:#?}", blueprint);
        CS_BLUEPRINT.with(|bp| *bp.borrow_mut() = Some(blueprint));
        Self
    }
}

impl Drop for CsBlueprintGuard {
    fn drop(&mut self) {
        CS_BLUEPRINT.with(|bp| *bp.borrow_mut() = None);
    }
}

/// Generic circuit that implements `Circuit<vesta::Scalar>` dynamically.
///
/// Used for VK deserialization without needing the original Rust circuit type.
/// In v2 format, the serialized CS is included alongside the VK, so this only
/// needs to match the column structure — gates and lookups come from the CS.
#[derive(Debug, Clone)]
pub struct DynamicCircuit<F: group::ff::PrimeField> {
    _z: std::marker::PhantomData<F>,
}

impl<F: group::ff::PrimeField> DynamicCircuit<F> {
    pub fn new() -> Self {
        Self {
            _z: std::marker::PhantomData,
        }
    }
}

impl<F: group::ff::PrimeField> Circuit<F> for DynamicCircuit<F> {
    type Config = ();
    type FloorPlanner = halo2_proofs::circuit::SimpleFloorPlanner;

    fn without_witnesses(&self) -> Self {
        Self::new()
    }

    fn configure(meta: &mut ConstraintSystem<F>) -> Self::Config {
        CS_BLUEPRINT.with(|bp_cell| {
            if let Some(blueprint) = &*bp_cell.borrow() {
                // Re-create the exact column structure
                for _ in 0..blueprint.num_fixed_columns {
                    let col = meta.fixed_column();
                    meta.enable_equality(col);
                }
                for _ in 0..blueprint.num_advice_columns {
                    let col = meta.advice_column();
                    meta.enable_equality(col);
                }
                for _ in 0..blueprint.num_instance_columns {
                    let col = meta.instance_column();
                    meta.enable_equality(col);
                }
                for _ in 0..blueprint.num_selectors {
                    meta.selector();
                }

                // Re-apply permutation columns (critical for correct VK read)
                for &col in &blueprint.permutation_columns {
                    meta.enable_equality(col);
                }
            } else {
                eprintln!("Warning: DynamicCircuit::configure called without CsBlueprint");
            }
        });
        ()
    }

    fn synthesize(
        &self,
        _config: Self::Config,
        _layouter: impl Layouter<F>,
    ) -> Result<(), plonk::Error> {
        // unimplemented as vm does not support proof creation
        Ok(())
    }
}

/// A struct defining a circuit compatible with the zk-wasmvm.
#[derive(Debug)]
pub struct CosmwasmCircuit<C> {
    pub(crate) circuit: C,
}

impl<C> CosmwasmCircuit<C> {
    pub fn new(circuit: C) -> Self {
        Self { circuit }
    }
}

impl<C, F> halo2_proofs::plonk::Circuit<F> for CosmwasmCircuit<C>
where
    C: Circuit<F>,
    F: group::ff::Field,
{
    type Config = C::Config;
    type FloorPlanner = C::FloorPlanner;

    fn without_witnesses(&self) -> Self {
        CosmwasmCircuit {
            circuit: self.circuit.without_witnesses(),
        }
    }

    fn configure(meta: &mut ConstraintSystem<F>) -> Self::Config {
        C::configure(meta)
    }

    fn synthesize(
        &self,
        config: Self::Config,
        layouter: impl Layouter<F>,
    ) -> Result<(), plonk::Error> {
        self.circuit.synthesize(config, layouter)
    }
}

impl core::fmt::Debug for Proof {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        if f.alternate() {
            f.debug_tuple("Proof").field(&self.0).finish()
        } else {
            f.debug_tuple("Proof")
                .field(&format_args!("{} bytes", self.0.len()))
                .finish()
        }
    }
}
