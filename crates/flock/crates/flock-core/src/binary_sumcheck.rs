//! Packed sumcheck for one data-parallel binary layer.
//!
//! A segment of `B` bits is one table key. Every pair of input segments is one
//! of `2^{2B}` patterns, so the `b`-sum is a lookup plus an accumulator instead
//! of a field multiply per gate per bit. The verifier's check is unchanged:
//! the `B` evaluations are the unique degree-`< B` polynomial on the segment
//! points, and their sum is the layer claim.
//!
//! Points `0..B-1` are embedded as distinct `GF(2^128)` elements (`2` is not
//! zero: it is the element with bit 1 set). Characteristic 2 makes subtraction
//! addition, which is why the Lagrange weights use `+`.

use flock_field::F128;

/// Bits packed into one segment. `2^{2B} = 65536` patterns, each `B` words.
pub const SEGMENT_BITS: usize = 8;
const PATTERNS: usize = 1 << (2 * SEGMENT_BITS);

/// Evaluations of a degree-`< SEGMENT_BITS` polynomial at the segment points.
#[derive(Clone, Copy)]
struct SegEval([F128; SEGMENT_BITS]);

impl SegEval {
    fn zero() -> Self {
        Self([F128::ZERO; SEGMENT_BITS])
    }

    fn add_scaled(&mut self, other: &Self, scale: F128) {
        for b in 0..SEGMENT_BITS {
            self.0[b] += other.0[b] * scale;
        }
    }
}

fn embed(point: usize) -> F128 {
    F128::new(point as u64, 0)
}

/// Lagrange basis `ℓ_b` at `tilde`, on the embedded points `0..B-1`.
fn lagrange_at(b: usize, tilde: F128) -> F128 {
    let pb = embed(b);
    let mut num = F128::ONE;
    let mut den = F128::ONE;
    for i in 0..SEGMENT_BITS {
        if i == b {
            continue;
        }
        let pi = embed(i);
        den *= pi + pb;
        num *= pi + tilde;
    }
    num * den.inv()
}

fn eq_row(tilde_b: F128) -> [F128; SEGMENT_BITS] {
    std::array::from_fn(|b| lagrange_at(b, tilde_b))
}

/// `g_{vx,vy}(b) = ℓ_b(tilde_b) · bit_b(vx) · bit_b(vy)` for every pattern.
pub struct PackedTable {
    rows: Vec<SegEval>,
}

impl PackedTable {
    pub fn precompute(tilde_b: F128) -> Self {
        let eq = eq_row(tilde_b);
        let n = 1usize << SEGMENT_BITS;
        let mut rows = vec![SegEval::zero(); PATTERNS];
        for vx in 0..n {
            for vy in 0..n {
                let mut g = SegEval::zero();
                for b in 0..SEGMENT_BITS {
                    let xb = F128::new(((vx >> b) & 1) as u64, 0);
                    let yb = F128::new(((vy >> b) & 1) as u64, 0);
                    g.0[b] = eq[b] * xb * yb;
                }
                rows[(vx << SEGMENT_BITS) | vy] = g;
            }
        }
        Self { rows }
    }
}

/// One data-parallel multiplication. `coeff` is the wiring weight at this gate
/// (the `eq` on the segment index). `vx` and `vy` pack the `B` input bits.
pub struct MulWire {
    pub coeff: F128,
    pub vx: u8,
    pub vy: u8,
}

/// Evaluations of `f(b)` and how many segment-polynomial scales the packed
/// pass performed. That count is `2^{2B} · B`, independent of the wire count.
pub struct PackedSum {
    pub evals: [F128; SEGMENT_BITS],
    pub poly_scales: usize,
}

impl PackedSum {
    pub fn sum(&self) -> F128 {
        self.evals.iter().copied().fold(F128::ZERO, |a, x| a + x)
    }
}

/// Accumulate every wire into its pattern bucket, then scale each of the
/// `2^{2B}` precomputed rows once.
pub fn sum_mul_wires(table: &PackedTable, wires: &[MulWire]) -> PackedSum {
    let mut acc = vec![F128::ZERO; PATTERNS];
    for w in wires {
        let slot = ((w.vx as usize) << SEGMENT_BITS) | w.vy as usize;
        acc[slot] += w.coeff;
    }
    let mut result = SegEval::zero();
    for (row, scale) in table.rows.iter().zip(acc) {
        result.add_scaled(row, scale);
    }
    PackedSum {
        evals: result.0,
        poly_scales: PATTERNS * SEGMENT_BITS,
    }
}

#[cfg(test)]
fn naive_sum(tilde_b: F128, wires: &[MulWire]) -> [F128; SEGMENT_BITS] {
    let eq = eq_row(tilde_b);
    let mut out = [F128::ZERO; SEGMENT_BITS];
    for w in wires {
        for b in 0..SEGMENT_BITS {
            let xb = F128::new(((w.vx >> b) & 1) as u64, 0);
            let yb = F128::new(((w.vy >> b) & 1) as u64, 0);
            out[b] += eq[b] * xb * yb * w.coeff;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lagrange_is_the_segment_basis() {
        for k in 0..SEGMENT_BITS {
            let row = eq_row(embed(k));
            for b in 0..SEGMENT_BITS {
                let expect = if b == k { F128::ONE } else { F128::ZERO };
                assert_eq!(row[b], expect, "ℓ_{b}(point {k})");
            }
        }
    }

    #[test]
    fn packed_sum_matches_the_gate_sum() {
        let tilde = F128::new(0x1234_5678, 0x9abc);
        let table = PackedTable::precompute(tilde);
        assert_eq!(table.rows.len(), PATTERNS);
        // Repeated patterns: the accumulator must merge them.
        let wires = [
            MulWire { coeff: F128::new(3, 0), vx: 0b1010_0110, vy: 0b0101_1001 },
            MulWire { coeff: F128::new(5, 0), vx: 0b1010_0110, vy: 0b0101_1001 },
            MulWire { coeff: F128::new(7, 0), vx: 0b1111_0000, vy: 0b0000_1111 },
            MulWire { coeff: F128::new(9, 0), vx: 0, vy: 0xff },
            MulWire { coeff: F128::new(11, 0), vx: 0xff, vy: 0xff },
        ];
        let packed = sum_mul_wires(&table, &wires);
        assert_eq!(packed.evals, naive_sum(tilde, &wires));
        assert_eq!(packed.poly_scales, PATTERNS * SEGMENT_BITS);
        let mut claim = F128::ZERO;
        for e in naive_sum(tilde, &wires) {
            claim += e;
        }
        assert_eq!(packed.sum(), claim);
    }
}
