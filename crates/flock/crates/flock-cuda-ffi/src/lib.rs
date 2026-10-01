//! FFI bridge to the cuda-ghash GPU prover.
//!
//! The `gpu` feature gates the whole surface: without it this crate is empty
//! and costs nothing to build. The C ABI is defined by
//! `cuda-ghash/prove_ffi.cu`; the roundtrip test in `tests/` deserializes the
//! returned bytes into the flock proof types and runs the Rust verifier.

#[cfg(feature = "gpu")]
pub mod gpu {
    unsafe extern "C" {
        /// Returns the CUDA device count as a link-and-launch smoke check
        /// (negative on CUDA runtime error).
        pub fn flock_cuda_device_count() -> i32;
    }

    /// Safe wrapper: number of visible CUDA devices, or an error code < 0.
    pub fn device_count() -> i32 {
        unsafe { flock_cuda_device_count() }
    }
}
