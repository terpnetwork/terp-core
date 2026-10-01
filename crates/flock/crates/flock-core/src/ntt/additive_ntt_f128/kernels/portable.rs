use crate::field::F128;

#[inline]
pub(super) fn butterfly_row_pair(top: &mut [F128], bot: &mut [F128], twiddle: F128) {
    for lane in 0..top.len() {
        let v = bot[lane];
        let new_u = top[lane] + v * twiddle;
        top[lane] = new_u;
        bot[lane] = v + new_u;
    }
}

#[allow(clippy::too_many_arguments)]
#[inline]
pub(super) fn butterfly_fused_2layer(
    a: &mut [F128],
    b: &mut [F128],
    c: &mut [F128],
    d: &mut [F128],
    t_outer: F128,
    t_inner_a: F128,
    t_inner_b: F128,
) {
    for lane in 0..a.len() {
        let mut xa = a[lane];
        let mut xb = b[lane];
        let mut xc = c[lane];
        let mut xd = d[lane];
        let na = xa + xc * t_outer;
        xc += na;
        xa = na;
        let nb = xb + xd * t_outer;
        xd += nb;
        xb = nb;
        let na2 = xa + xb * t_inner_a;
        xb += na2;
        xa = na2;
        let nc2 = xc + xd * t_inner_b;
        xd += nc2;
        xc = nc2;
        a[lane] = xa;
        b[lane] = xb;
        c[lane] = xc;
        d[lane] = xd;
    }
}

/// Fused THREE-layer butterfly over one 8-row group, all interleaved lanes.
/// Row k of the group is `rows[k]`; layer L pairs (k, k+4) @ `t0`, layer L+1
/// pairs (k, k+2) within each half @ `t1[half]`, layer L+2 pairs (k, k+1)
/// within each quarter @ `t2[quarter]`. Scalar per lane ON PURPOSE — the
/// field muls ILP through the compiler (the explicit-batching regression),
/// and 8 values + 7 twiddles in flight stays far from the register pressure
/// that sank the generic 16-point kernel on aarch64.
#[inline]
pub(super) fn butterfly_fused_3layer(
    rows: [&mut [F128]; 8],
    t0: F128,
    t1: &[F128; 2],
    t2: &[F128; 4],
) {
    #[inline(always)]
    fn bf(v: &mut [F128; 8], u: usize, w: usize, t: F128) {
        let nu = v[u] + v[w] * t;
        v[w] += nu;
        v[u] = nu;
    }
    let [r0, r1, r2, r3, r4, r5, r6, r7] = rows;
    debug_assert!(
        [&r1, &r2, &r3, &r4, &r5, &r6, &r7]
            .iter()
            .all(|r| r.len() == r0.len())
    );
    for lane in 0..r0.len() {
        let mut v = [
            r0[lane], r1[lane], r2[lane], r3[lane], r4[lane], r5[lane], r6[lane], r7[lane],
        ];
        bf(&mut v, 0, 4, t0);
        bf(&mut v, 1, 5, t0);
        bf(&mut v, 2, 6, t0);
        bf(&mut v, 3, 7, t0);
        bf(&mut v, 0, 2, t1[0]);
        bf(&mut v, 1, 3, t1[0]);
        bf(&mut v, 4, 6, t1[1]);
        bf(&mut v, 5, 7, t1[1]);
        bf(&mut v, 0, 1, t2[0]);
        bf(&mut v, 2, 3, t2[1]);
        bf(&mut v, 4, 5, t2[2]);
        bf(&mut v, 6, 7, t2[3]);
        r0[lane] = v[0];
        r1[lane] = v[1];
        r2[lane] = v[2];
        r3[lane] = v[3];
        r4[lane] = v[4];
        r5[lane] = v[5];
        r6[lane] = v[6];
        r7[lane] = v[7];
    }
}

#[inline]
pub(super) fn butterfly_fused_4layer(values: &mut [F128; 16], twiddles: &[F128; 15]) {
    #[inline(always)]
    fn butterfly(values: &mut [F128; 16], u: usize, v: usize, twiddle: F128) {
        let new_u = values[u] + values[v] * twiddle;
        values[v] += new_u;
        values[u] = new_u;
    }

    for i in 0..8 {
        butterfly(values, i, i + 8, twiddles[0]);
    }
    for s in 0..2 {
        for i in 0..4 {
            butterfly(values, 8 * s + i, 8 * s + i + 4, twiddles[1 + s]);
        }
    }
    for s in 0..4 {
        for i in 0..2 {
            butterfly(values, 4 * s + i, 4 * s + i + 2, twiddles[3 + s]);
        }
    }
    for s in 0..8 {
        butterfly(values, 2 * s, 2 * s + 1, twiddles[7 + s]);
    }
}

/// # Safety
/// The caller guarantees that every selected row and lane is valid and that
/// concurrent calls use disjoint row groups.
#[cfg(not(all(
    target_arch = "x86_64",
    target_feature = "avx512f",
    target_feature = "vpclmulqdq"
)))]
pub(super) unsafe fn butterfly_fused_4layer_row(
    ptr: *mut F128,
    sixteenth: usize,
    num_ntts: usize,
    r: usize,
    twiddles: &[F128; 15],
) {
    // SAFETY: caller supplies the pointer geometry and disjointness contract.
    unsafe {
        for lane in 0..num_ntts {
            let mut values = [F128::ZERO; 16];
            for (i, value) in values.iter_mut().enumerate() {
                *value = *ptr.add((i * sixteenth + r) * num_ntts + lane);
            }
            butterfly_fused_4layer(&mut values, twiddles);
            for (i, value) in values.iter().enumerate() {
                *ptr.add((i * sixteenth + r) * num_ntts + lane) = *value;
            }
        }
    }
}
