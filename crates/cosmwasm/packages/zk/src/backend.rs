//! Optional verify backends for Path A (`proof_instance_verify`).
//!
//! - [`CpuBackend`] is always available and is the **CPU golden** reference.
//! - [`GpuBackend`] is compiled only with feature `gpu`. Device open uses a
//!   structured probe (`probe_gpu` / `TERP_GPU`); **this residual (R4) still
//!   never acquires a real accelerator** — CPU fallback only (design + probe
//!   scaffold; not production GPU verify).
//!
//! Gas is charged by the host **before** backend work. Backends must not derive
//! gas from wall-clock timers. Device presence must not change accept/reject.
//!
//! See `docs/research/gpu-accel/DESIGN-G1-verifier-backend.md` and
//! `docs/research/gpu-accel/DESIGN-R4-kernel-path.md`.

use crate::{AnyInstance, AnyVerifyingKey, Proof, ZkResult};

/// One item for [`VerifierBackend::batch_verify`].
#[derive(Clone, Copy)]
pub struct VerifyItem<'a> {
    pub vk: &'a AnyVerifyingKey,
    pub proof: &'a Proof,
    pub instances: &'a [AnyInstance],
}

/// Backend for eligible ZK verify ops (Path A).
///
/// Determinism: accept/reject must match [`CpuBackend`] on the same inputs.
pub trait VerifierBackend {
    /// Single-proof verify (Path A today).
    fn verify(
        &self,
        vk: &AnyVerifyingKey,
        proof: &Proof,
        instances: &[AnyInstance],
    ) -> ZkResult<()>;

    /// Batch-first API for amortization (MSM / pairing / IPA batch).
    /// Default: sequential `verify` (correct, no amortization). Future
    /// `GpuBackend` may override when real kernels land.
    fn batch_verify(&self, items: &[VerifyItem<'_>]) -> ZkResult<()> {
        for item in items {
            self.verify(item.vk, item.proof, item.instances)?;
        }
        Ok(())
    }

    fn name(&self) -> &'static str;
}

/// Always available. Golden reference. Feature-independent.
#[derive(Debug, Default, Clone, Copy)]
pub struct CpuBackend;

impl VerifierBackend for CpuBackend {
    fn verify(
        &self,
        vk: &AnyVerifyingKey,
        proof: &Proof,
        instances: &[AnyInstance],
    ) -> ZkResult<()> {
        // Existing golden path: Proof::verify → AnyVerifyingKey::verify
        proof.verify(vk, instances)
    }

    fn name(&self) -> &'static str {
        "cpu"
    }
}

/// Placeholder for a future GPU device binding.
///
/// R4: never constructed — probe scaffold only; no real kernels.
#[cfg(feature = "gpu")]
#[derive(Debug)]
pub struct GpuDeviceHandle {
    _private: (),
}

/// Structured outcome of a GPU capability probe (`cfg(feature = "gpu")` only).
///
/// Never a consensus correctness input: accept/reject must match [`CpuBackend`]
/// regardless of status. See DESIGN-R4-kernel-path.md §4.
#[cfg(feature = "gpu")]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GpuProbeStatus {
    /// Operator disabled GPU via `TERP_GPU` (`0` / `false` / `off` / `no`).
    DisabledByEnv,
    /// No openable device / no kernel binding (default R4 state).
    Unavailable,
    /// `TERP_GPU` hints on (`1` / `true` / `on` / `yes`) but still no device.
    HintedButNoDevice,
    /// Device opened successfully (not reached until real vendor path lands).
    Available,
}

/// Diagnostics from [`probe_gpu`]. Safe to log; must not feed gas or guest I/O.
#[cfg(feature = "gpu")]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GpuProbeReport {
    pub status: GpuProbeStatus,
    /// Static reason for tests / metrics labels.
    pub reason: &'static str,
}

#[cfg(feature = "gpu")]
impl GpuProbeReport {
    pub fn is_active(&self) -> bool {
        matches!(self.status, GpuProbeStatus::Available)
    }
}

/// Optional runtime env: detect / disable hint only (never consensus input).
#[cfg(feature = "gpu")]
const TERP_GPU_ENV: &str = "TERP_GPU";

/// Parse `TERP_GPU` into disable / hint / neutral.
///
/// | value (case-insensitive trim) | meaning |
/// |-------------------------------|---------|
/// | unset, empty, unknown         | neutral |
/// | `1`, `true`, `on`, `yes`      | prefer GPU when available |
/// | `0`, `false`, `off`, `no`     | force CPU path |
#[cfg(feature = "gpu")]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TerpGpuEnv {
    Neutral,
    Prefer,
    Disable,
}

#[cfg(feature = "gpu")]
fn parse_terp_gpu_env(raw: Option<&str>) -> TerpGpuEnv {
    let Some(s) = raw else {
        return TerpGpuEnv::Neutral;
    };
    let t = s.trim();
    if t.is_empty() {
        return TerpGpuEnv::Neutral;
    }
    let lower = t.to_ascii_lowercase();
    match lower.as_str() {
        "0" | "false" | "off" | "no" => TerpGpuEnv::Disable,
        "1" | "true" | "on" | "yes" => TerpGpuEnv::Prefer,
        _ => TerpGpuEnv::Neutral,
    }
}

/// Core probe from an already-parsed env preference (testable; no process env).
///
/// R4: never returns [`GpuProbeStatus::Available`] — design + probe scaffold only.
#[cfg(feature = "gpu")]
fn probe_gpu_with_env(env: TerpGpuEnv) -> GpuProbeReport {
    match env {
        TerpGpuEnv::Disable => GpuProbeReport {
            status: GpuProbeStatus::DisabledByEnv,
            reason: "TERP_GPU disables GPU path",
        },
        TerpGpuEnv::Prefer => GpuProbeReport {
            // No vendor open path yet — honest non-Available.
            status: GpuProbeStatus::HintedButNoDevice,
            reason: "TERP_GPU prefers GPU but no kernel/device binding",
        },
        TerpGpuEnv::Neutral => GpuProbeReport {
            status: GpuProbeStatus::Unavailable,
            reason: "no GPU kernel/device binding (probe scaffold)",
        },
    }
}

/// Probe for an accelerator without panicking and without hard CUDA/Metal deps.
///
/// Reads optional `TERP_GPU` (hint / disable only). R4 never reports Available.
#[cfg(feature = "gpu")]
pub fn probe_gpu() -> GpuProbeReport {
    let env = parse_terp_gpu_env(std::env::var(TERP_GPU_ENV).ok().as_deref());
    probe_gpu_with_env(env)
}

/// Open a device handle if probe reports [`GpuProbeStatus::Available`].
///
/// R4: always `None` (no production GPU verify). No hard CUDA/Metal deps.
#[cfg(feature = "gpu")]
fn try_open_gpu_device(report: &GpuProbeReport) -> Option<GpuDeviceHandle> {
    if !report.is_active() {
        return None;
    }
    // Future: bind vendor handle here under optional deps only.
    // Unreachable until a real open path sets Available.
    None
}

/// Compiled only with feature `gpu`. Runtime device detect; falls back to CPU.
///
/// **R4 residual:** structured probe + env (`TERP_GPU`); still **never** opens a
/// real device. Every verify call is CPU-equivalent. Real kernels may land later
/// without changing the trait surface or host gas model.
#[cfg(feature = "gpu")]
#[derive(Debug)]
pub struct GpuBackend {
    /// `None` ⇒ treat as CPU (no device / init failed / scaffold).
    device: Option<GpuDeviceHandle>,
    /// Last probe report (diagnostics; not guest-visible).
    probe: GpuProbeReport,
}

#[cfg(feature = "gpu")]
impl GpuBackend {
    /// Probe for an accelerator. Must not panic.
    ///
    /// R4: always inactive (CPU fallback). See [`probe_gpu`].
    pub fn try_detect() -> Self {
        let probe = probe_gpu();
        let device = try_open_gpu_device(&probe);
        Self { device, probe }
    }

    pub fn is_active(&self) -> bool {
        self.device.is_some()
    }

    /// Structured probe outcome from the last detect (tests / bench labels).
    pub fn probe_report(&self) -> GpuProbeReport {
        self.probe
    }
}

/// Scaffolding GPU verify: no kernel. Callers must treat errors as
/// "fall back to CPU" when a real device exists; with `device=None` the
/// [`VerifierBackend`] impl never reaches this.
#[cfg(feature = "gpu")]
#[allow(dead_code)]
fn gpu_verify(
    _dev: &GpuDeviceHandle,
    _vk: &AnyVerifyingKey,
    _proof: &Proof,
    _instances: &[AnyInstance],
) -> Result<(), GpuBackendError> {
    Err(GpuBackendError::NotImplemented)
}

#[cfg(feature = "gpu")]
#[derive(Debug)]
#[allow(dead_code)]
enum GpuBackendError {
    /// Scaffolding: kernels not implemented.
    NotImplemented,
}

#[cfg(feature = "gpu")]
impl VerifierBackend for GpuBackend {
    fn verify(
        &self,
        vk: &AnyVerifyingKey,
        proof: &Proof,
        instances: &[AnyInstance],
    ) -> ZkResult<()> {
        match &self.device {
            Some(dev) => {
                // Future: GPU kernel must match CpuBackend accept/reject.
                // On kernel/driver error: fall back to CPU (same Result shape).
                match gpu_verify(dev, vk, proof, instances) {
                    Ok(()) => Ok(()),
                    Err(_backend_err) => CpuBackend.verify(vk, proof, instances),
                }
            }
            None => CpuBackend.verify(vk, proof, instances),
        }
    }

    fn batch_verify(&self, items: &[VerifyItem<'_>]) -> ZkResult<()> {
        // Prefer real batch on device when active; scaffolding falls back to CPU loop.
        if self.device.is_some() {
            // No amortized kernel yet — sequential with per-item CPU fallback.
            for item in items {
                self.verify(item.vk, item.proof, item.instances)?;
            }
            Ok(())
        } else {
            CpuBackend.batch_verify(items)
        }
    }

    fn name(&self) -> &'static str {
        if self.device.is_some() {
            "gpu"
        } else {
            "gpu-fallback-cpu"
        }
    }
}

/// Process-level selection used by host imports.
#[derive(Debug)]
pub enum SelectedBackend {
    Cpu(CpuBackend),
    #[cfg(feature = "gpu")]
    Gpu(GpuBackend),
}

impl SelectedBackend {
    pub fn name(&self) -> &'static str {
        match self {
            SelectedBackend::Cpu(b) => b.name(),
            #[cfg(feature = "gpu")]
            SelectedBackend::Gpu(b) => b.name(),
        }
    }

    pub fn verify(
        &self,
        vk: &AnyVerifyingKey,
        proof: &Proof,
        instances: &[AnyInstance],
    ) -> ZkResult<()> {
        match self {
            SelectedBackend::Cpu(b) => b.verify(vk, proof, instances),
            #[cfg(feature = "gpu")]
            SelectedBackend::Gpu(b) => b.verify(vk, proof, instances),
        }
    }

    pub fn batch_verify(&self, items: &[VerifyItem<'_>]) -> ZkResult<()> {
        match self {
            SelectedBackend::Cpu(b) => b.batch_verify(items),
            #[cfg(feature = "gpu")]
            SelectedBackend::Gpu(b) => b.batch_verify(items),
        }
    }
}

/// Select backend for Path A host import.
///
/// - Feature `gpu` OFF: always [`CpuBackend`].
/// - Feature `gpu` ON: try GPU; if inactive/unavailable, still prefer exposing
///   [`GpuBackend`] only when active; otherwise CPU. Scaffolding never activates GPU.
pub fn select_backend() -> SelectedBackend {
    #[cfg(feature = "gpu")]
    {
        let g = GpuBackend::try_detect();
        if g.is_active() {
            return SelectedBackend::Gpu(g);
        }
    }
    SelectedBackend::Cpu(CpuBackend)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cpu_backend_name() {
        assert_eq!(CpuBackend.name(), "cpu");
        assert_eq!(select_backend().name(), "cpu");
    }

    #[test]
    fn cpu_batch_verify_empty_ok() {
        CpuBackend.batch_verify(&[]).unwrap();
    }

    #[cfg(feature = "gpu")]
    #[test]
    fn gpu_stub_is_inactive_fallback_cpu() {
        // Ensure disable path does not leave process env dirty for other tests:
        // run detect under a clean-ish preference (do not force Available).
        let g = GpuBackend::try_detect();
        assert!(!g.is_active(), "R4 probe must not claim a live GPU device");
        assert_eq!(g.name(), "gpu-fallback-cpu");
        assert!(!g.probe_report().is_active());
        // select_backend prefers CPU when GPU inactive
        assert_eq!(select_backend().name(), "cpu");
    }

    #[cfg(feature = "gpu")]
    #[test]
    fn probe_gpu_with_env_table() {
        // No process env mutation — parallel-safe.
        let off = probe_gpu_with_env(TerpGpuEnv::Disable);
        assert_eq!(off.status, GpuProbeStatus::DisabledByEnv);
        assert!(!off.is_active());

        let hint = probe_gpu_with_env(TerpGpuEnv::Prefer);
        assert_eq!(hint.status, GpuProbeStatus::HintedButNoDevice);
        assert!(!hint.is_active(), "hint must not imply production device");

        let neutral = probe_gpu_with_env(TerpGpuEnv::Neutral);
        assert_eq!(neutral.status, GpuProbeStatus::Unavailable);
        assert!(!neutral.is_active());

        // try_open never constructs a handle in R4
        assert!(try_open_gpu_device(&hint).is_none());
        assert!(try_open_gpu_device(&neutral).is_none());
        assert!(try_open_gpu_device(&off).is_none());
    }

    #[cfg(feature = "gpu")]
    #[test]
    fn parse_terp_gpu_env_table() {
        assert_eq!(parse_terp_gpu_env(None), TerpGpuEnv::Neutral);
        assert_eq!(parse_terp_gpu_env(Some("")), TerpGpuEnv::Neutral);
        assert_eq!(parse_terp_gpu_env(Some("  ")), TerpGpuEnv::Neutral);
        assert_eq!(parse_terp_gpu_env(Some("1")), TerpGpuEnv::Prefer);
        assert_eq!(parse_terp_gpu_env(Some("TRUE")), TerpGpuEnv::Prefer);
        assert_eq!(parse_terp_gpu_env(Some("on")), TerpGpuEnv::Prefer);
        assert_eq!(parse_terp_gpu_env(Some("0")), TerpGpuEnv::Disable);
        assert_eq!(parse_terp_gpu_env(Some("No")), TerpGpuEnv::Disable);
        assert_eq!(parse_terp_gpu_env(Some("maybe")), TerpGpuEnv::Neutral);
    }

    /// CpuBackend and GpuBackend(fallback) must agree on accept/reject for the
    /// committed BN254 square golden vector (when `bn254` + fixtures present).
    #[cfg(all(feature = "gpu", feature = "bn254"))]
    #[test]
    fn cpu_and_gpu_fallback_agree_on_square_golden() {
        use crate::{AnyInstance, AnyVerifyingKey, Proof};
        use std::path::PathBuf;

        let td = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("testdata");
        let blob = match std::fs::read(td.join("square_vk.bin")) {
            Ok(b) => b,
            Err(_) => {
                eprintln!("skip: missing square_vk.bin");
                return;
            }
        };
        let proof_bytes = match std::fs::read(td.join("square_proof.bin")) {
            Ok(b) => b,
            Err(_) => return,
        };
        let public = match std::fs::read(td.join("square_public.bin")) {
            Ok(b) => b,
            Err(_) => return,
        };

        let vk = AnyVerifyingKey::try_from(blob.as_slice()).expect("vk");
        let proof = Proof::new(proof_bytes);
        let inst = AnyInstance::try_from_bytes(4u32, &public).expect("instance");
        let instances = [inst];

        let cpu = CpuBackend.verify(&vk, &proof, &instances);
        let gpu = GpuBackend::try_detect().verify(&vk, &proof, &instances);
        assert_eq!(
            cpu.is_ok(),
            gpu.is_ok(),
            "CPU vs GPU-fallback accept/reject mismatch: cpu={cpu:?} gpu={gpu:?}"
        );
        assert!(
            cpu.is_ok(),
            "square golden should verify true on CPU: {cpu:?}"
        );

        // Bit-flip proof: both must reject (VerifyFailed or format)
        let mut bad = proof.0.clone();
        if let Some(last) = bad.last_mut() {
            *last ^= 0x01;
        }
        let bad_proof = Proof::new(bad);
        let cpu_bad = CpuBackend.verify(&vk, &bad_proof, &instances);
        let gpu_bad = GpuBackend::try_detect().verify(&vk, &bad_proof, &instances);
        assert!(cpu_bad.is_err());
        assert!(gpu_bad.is_err());
        assert_eq!(
            cpu_bad.as_ref().err().map(|e| e.is_verify_failed()),
            gpu_bad.as_ref().err().map(|e| e.is_verify_failed()),
        );
    }
}
