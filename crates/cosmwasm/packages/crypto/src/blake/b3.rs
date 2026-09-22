//! BLAKE3-256 (native CPU, deterministic fixed 32-byte output).
//!
//! BLAKE3 may use multi-core internally for large inputs but still produces a
//! **bit-identical** digest for a given message and output length. Do not
//! replace this with a GPU path on the consensus host.

use blake3;

/// BLAKE3 with 32-byte output (default XOF length).
pub fn blake3_256(msg: &[u8]) -> [u8; 32] {
    *blake3::hash(msg).as_bytes()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_is_stable() {
        assert_eq!(blake3_256(b""), blake3_256(b""));
    }

    #[test]
    fn differs_on_input() {
        assert_ne!(blake3_256(b"a"), blake3_256(b"b"));
    }
}
