//! BLAKE2b-512 (native CPU, deterministic).

use blake2::{Blake2b512, Digest};

/// BLAKE2b with 64-byte output.
pub fn blake2b_512(msg: &[u8]) -> [u8; 64] {
    let mut hasher = Blake2b512::new();
    hasher.update(msg);
    let out = hasher.finalize();
    let mut arr = [0u8; 64];
    arr.copy_from_slice(&out);
    arr
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_is_stable() {
        assert_eq!(blake2b_512(b""), blake2b_512(b""));
    }
}
