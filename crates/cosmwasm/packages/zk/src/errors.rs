use std::{array::TryFromSliceError, io::Error};

use halo2_proofs::plonk;
use thiserror::Error;

pub type ZkResult<T> = core::result::Result<T, ZkError>;

#[derive(Error, Debug)]
#[non_exhaustive]
pub enum ZkError {
    #[error("Aborted: {}", err)]
    Aborted { err: String },
    #[error("Invalid Scalar")]
    InvalidScalar,
    #[error("CurveMismatch")]
    CurveMismatch,
    #[error("UnsupportedCurve: {0}")]
    UnsupportedCurve(u32),
    #[error("Aborted: {}", err)]
    IoErr { err: Error },
    #[error("{0}")]
    TryFromSliceError(#[from] TryFromSliceError),
    #[error("{0}")]
    PlonkError(#[from] plonk::Error),
    #[error("calculated hash doesn't match stored hash")]
    IntegrityErr {},
    /// Proof well-formed but Groth16/Plonk verification returned false.
    /// Host Path A maps this to `Ok(1)` (invalid), not a VmError.
    #[error("proof verification failed")]
    VerifyFailed,
    /// Malformed proof, VK, public inputs, or Fr encoding (format error).
    /// Host Path A maps this to `VmError` / contract Err (not silent accept).
    #[error("zk format error: {0}")]
    FormatErr(String),
}

impl ZkError {
    pub fn new_err<T: Into<String>>(e: T) -> Self {
        ZkError::Aborted { err: e.into() }
    }
    pub fn new_io<T: Into<Error>>(e: T) -> Self {
        ZkError::IoErr { err: e.into() }
    }
    pub fn format_err<T: Into<String>>(e: T) -> Self {
        ZkError::FormatErr(e.into())
    }
    /// True when the error is a clean crypto reject (host returns Ok(1)).
    pub fn is_verify_failed(&self) -> bool {
        matches!(self, ZkError::VerifyFailed)
    }
    /// True when the error is a format/parse problem (host returns Err).
    pub fn is_format_err(&self) -> bool {
        matches!(
            self,
            ZkError::FormatErr(_)
                | ZkError::InvalidScalar
                | ZkError::CurveMismatch
                | ZkError::UnsupportedCurve(_)
                | ZkError::IntegrityErr {}
                | ZkError::TryFromSliceError(_)
        )
    }
}

impl From<Error> for ZkError {
    fn from(e: Error) -> Self {
        ZkError::new_io(e)
    }
}
