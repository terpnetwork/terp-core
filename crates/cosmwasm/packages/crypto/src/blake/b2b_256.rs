//! BLAKE2b-256 (native CPU, deterministic).

use blake2::{Blake2b, Digest};
use digest::consts::U32;

/// BLAKE2b with 32-byte output (BLAKE2b-256).
///
/// Pure function of `msg` — safe for consensus host import.
pub fn blake2b_256(msg: &[u8]) -> [u8; 32] {
    let mut hasher = Blake2b::<U32>::new();
    hasher.update(msg);
    let out = hasher.finalize();
    let mut arr = [0u8; 32];
    arr.copy_from_slice(&out);
    arr
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_is_stable() {
        let a = blake2b_256(b"");
        let b = blake2b_256(b"");
        assert_eq!(a, b);
        assert_eq!(a.len(), 32);
    }

    #[test]
    fn differs_on_input() {
        assert_ne!(blake2b_256(b"a"), blake2b_256(b"b"));
    }
}
