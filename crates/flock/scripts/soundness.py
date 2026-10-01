#!/usr/bin/env python3
"""Whole-protocol soundness calculator for the Ligerito ladder in the
Johnson list-decoding regime, with optional out-of-domain (OOD) binding.

Protocol shape (mirrors `default_config` in src/pcs/ligerito.rs):
  L0:  message 2^(log_n - initial_k) cols x 2^initial_k interleaved rows,
       rate 2^-log_inv_rate.
  L1+: while the running dim > 5, fold k = min(3, dim) variables per level;
       the rate index increases by 1 each level (rate halves).
  The final residual block (yr) is sent in the clear: no queries, no error.

Per-level error terms (bits = -log2):
  eps_pg    - proximity gap / correlated agreement, BCHKS25 (ePrint
              2025/2055) Thm 1.5 pairwise bound. Each level folds 2^k rows
              via k successive tensor challenges ("diamond" analysis, as in
              the Rust config derivation), so the level pays k line-version
              applications:
                  a = (2(m+1/2)^5 + 3(m+1/2)) / (3 rho^{3/2}) * n
                      + (m+1/2)/sqrt(rho)
                  eps_pg = k * a / q,   m = max(ceil(sqrt(rho)/(2 eta)), 3)
  L_int     - list size of the 2^k-wise interleaved code at radius
              theta = 1 - sqrt(rho) - eta, independent of the interleaving
              factor. Interleaving preserves relative distance (the interleaved
              code has the base code's distance delta = 1 - rho, only the
              alphabet grows to q^(2^k)), and the large-alphabet Johnson bound
              depends solely on (distance, radius), so below the Johnson radius
              1 - sqrt(rho) the interleaved list inherits the base single-code
              Johnson list size with no L_base^r blow-up:
                  L_int <= L_base <= 1/(2 eta sqrt(rho)).
              The GGR (arXiv:0811.4395, Thm 2.5) interleaved bound
              L_int <= C(b+r, r) * L_base^r is only needed to push the radius
              *past* the Johnson bound toward delta; Ligerito sits strictly
              below it (slack eta > 0), so that regime never applies and the
              plain Johnson bound is both correct and tighter. Mirrors
              johnson_interleaved_list_log2 in src/pcs/ligerito.rs.
  eps_ood   - probability s OOD samples fail to bind the prover to one list
              element. The level's message is a multilinear polynomial in
              mu = log_msg_cols + k variables (packed field elements), so a
              pair of distinct list elements collides per sample w.p. mu/q
              (Schwartz-Zippel); 'univariate' uses (k_dim-1)/(q-n) instead:
                  eps_ood <= C(L_int, 2) * (mu/q)^s
  eps_query - t queries at theta-far oracle:
                  s >= 1:  (sqrt(rho)+eta)^t        (bound to one codeword)
                  s == 0:  L_int * (sqrt(rho)+eta)^t (union bound over list)
              t is chosen per level as the minimum hitting --target.
  grind     - PoW bits needed per level so that the challenge-based terms
              (eps_pg, eps_ood) reach --target. Reported, not assumed.

The TOTAL is the sum of all per-level terms (after the reported grinding).

Caveat: composing OOD binding with folding challenges round-by-round needs
*mutual* correlated agreement (Haboeck, ePrint 2025/1184); this script only
does the per-term arithmetic.
"""

import argparse
import math
import sys


def derive_ladder(log_n: int, initial_k: int, log_inv_rate: int):
    """Replicate default_config's recursion shape from src/pcs/ligerito.rs.
    Returns a list of (log_msg_cols, k_interleave_log, log_inv_rate) and
    the final residual dim yr_log_n."""
    levels = [(log_n - initial_k, initial_k, log_inv_rate)]
    dim = log_n - initial_k
    rate_idx = log_inv_rate
    while dim > 5:
        k = min(3, dim)
        rate_idx += 1
        levels.append((dim - k, k, rate_idx))
        dim -= k
    return levels, dim


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--m", type=int, required=True,
                   help="log2 of witness bit count; log_n = m - log_packing")
    p.add_argument("--log-packing", type=int, default=7,
                   help="log2 bits per field element (default 7 = F_{2^128})")
    p.add_argument("--initial-k", type=int, default=6,
                   help="L0 interleaving log (repo configs use 6 = 64 rows)")
    p.add_argument("--log-inv-rate", type=int, default=1,
                   help="L0 rate index: rho_0 = 2^-log_inv_rate (default 1)")
    p.add_argument("--regime", choices=["johnson", "udr"], default="johnson",
                   help="johnson: theta = 1-sqrt(rho)-eta, list decoding, OOD "
                        "binding; udr: theta = (1-rho)/2 - eps*, unique "
                        "decoding (list size 1, no OOD), BCHKS25 Thm 1.4 "
                        "constant exceptional set a <= 2/eps*")
    p.add_argument("--proximity-loss", type=float, default=0.001,
                   help="eps* for the UDR regime (default 0.001)")
    p.add_argument("--johnson-from", type=int, default=None,
                   help="with --regime udr: switch to the Johnson regime from "
                        "this level onward (hybrid ladder). Levels below stay "
                        "UDR; pair with a larger --eta since the low-rate "
                        "levels can afford much more Johnson slack")
    p.add_argument("--eta", type=float, default=0.02,
                   help="slack below the Johnson radius at every level")
    p.add_argument("--field-bits", type=float, default=128.0, help="log2 |F|")
    p.add_argument("--ood-samples", type=int, default=1,
                   help="OOD samples s per level (0 = union bound over list)")
    p.add_argument("--ood-kind", choices=["multilinear", "univariate"],
                   default="multilinear")
    p.add_argument("--l0-zerocheck-ood", action="store_true",
                   help="treat the zerocheck->sumcheck transition as level 0's "
                        "OOD binding: the prover is already committed to one "
                        "claimed evaluation at the random challenge point, so "
                        "the bad event is a union over the list (not pairs): "
                        "eps = L_int * mu / q. Free - no extra transcript step.")
    p.add_argument("--query-grind", type=int, default=0,
                   help="PoW bits ground on each level's query challenge "
                        "before positions are sampled; reduces the per-level "
                        "query count by this many bits of target (default 0)")
    p.add_argument("--max-ood-grind", type=float, default=16.0,
                   help="if the OOD term alone would need more than this many "
                        "grinding bits, add OOD samples at that level instead "
                        "(default 16; set huge to disable)")
    p.add_argument("--target", type=float, default=None,
                   help="per-term security target in bits (overrides --overall)")
    p.add_argument("--overall", type=float, default=100.0,
                   help="overall protocol soundness target in bits; the "
                        "per-term target is overall + log2(#terms) (default 100)")
    args = p.parse_args()

    log_n = args.m - args.log_packing
    log_q = args.field_bits
    s = args.ood_samples
    eta = args.eta
    levels, yr_log_n = derive_ladder(log_n, args.initial_k, args.log_inv_rate)

    if args.regime == "udr" and args.johnson_from is None:
        s = 0
    if args.target is None:
        n_terms = len(levels) * (3 if s > 0 else 2)
        args.target = args.overall + math.log2(n_terms)

    print(f"m={args.m} (log_n={log_n} packed), initial interleave 2^{args.initial_k}, "
          f"eta={eta}, |F|=2^{log_q:g}, s={s} ({args.ood_kind}) OOD/level, "
          f"target {args.target:.1f} bits/term")
    print(f"{len(levels)} levels + final block yr_log_n={yr_log_n}\n")

    hdr = (f"{'lvl':>3} {'rho':>6} {'cols':>5} {'ilv':>4} {'n=2^':>4} "
           f"{'L_int':>6} {'s':>2} {'t':>4} {'pg':>6} {'ood':>6} {'query':>6} "
           f"{'cgrind':>6} {'qgrind':>6}")
    print(hdr)
    total_terms = []   # log2 of every error term, post-grinding
    total_queries = 0
    total_cgrind = 0
    total_qgrind = 0
    total_ood_samples = 0
    max_grind = 0
    total_bytes = 0
    for i, (log_cols, k_ilv, rate_idx) in enumerate(levels):
        rho = 2.0 ** -rate_idx
        sqrt_rho = math.sqrt(rho)
        if not eta < 1 - sqrt_rho:
            sys.exit(f"L{i}: eta {eta} >= 1-sqrt(rho) = {1-sqrt_rho:.4f}")
        log_block = log_cols + rate_idx       # codeword positions n_i
        n_i = 2 ** log_block
        k_dim = 2 ** log_cols                 # row message length

        regime_i = args.regime
        if args.regime == "udr" and args.johnson_from is not None \
                and i >= args.johnson_from:
            regime_i = "johnson"
        if regime_i == "udr":
            # unique decoding: theta = (1-rho)/2 - eps*, list size 1,
            # BCHKS25 Thm 1.4: exceptional set a <= 2/eps* (n-independent),
            # times the k-fold diamond tensor penalty
            theta = (1 - rho) / 2 - args.proximity_loss
            a = k_ilv * 2 / args.proximity_loss
            pg_bits = log_q - math.log2(a)
            log2_L_int = 0.0
        else:
            theta = 1 - sqrt_rho - eta
            # proximity gap: k_ilv pairwise (line) applications per level
            m_gs = max(math.ceil(sqrt_rho / (2 * eta)), 3)
            a = ((2 * (m_gs + 0.5) ** 5 + 3 * (m_gs + 0.5)) / (3 * rho ** 1.5) * n_i
                 + (m_gs + 0.5) / sqrt_rho)
            pg_bits = log_q - math.log2(k_ilv * a)

            # interleaved list size: below the Johnson radius the interleaved
            # code inherits the base single-code Johnson size, no L_base^r
            # blow-up (see docstring; mirrors ligerito.rs).
            L_base = 1 / (2 * eta * sqrt_rho)
            log2_L_int = math.log2(L_base)

        # OOD binding; escalate sample count while the OOD term alone would
        # need more than --max-ood-grind grinding bits
        s_i = s
        ood_bits = None
        if regime_i == "udr":
            s_i = 0  # unique decoding: list size 1, no OOD binding needed
        elif i == 0 and args.l0_zerocheck_ood:
            # zerocheck->sumcheck transition binds the committed multilinear
            # to one claimed evaluation at a random point in F^mu: union
            # bound over the list, one "sample", no transcript cost
            mu = log_cols + k_ilv
            ood_bits = -(log2_L_int + math.log2(mu) - log_q)
            s_i = 0
            # escalate with explicit pair-bound samples only if still short
            while args.target - ood_bits > args.max_ood_grind and s_i < 8:
                s_i += 1
                ood_bits = -((2 * log2_L_int - 1)
                             + s_i * (math.log2(mu) - log_q))
        elif s > 0:
            if args.ood_kind == "multilinear":
                mu = log_cols + k_ilv
                log2_coll1 = math.log2(mu) - log_q
            else:
                log2_coll1 = math.log2(max(k_dim - 1, 1)) - math.log2(2 ** log_q - n_i)
            while True:
                ood_bits = -((2 * log2_L_int - 1) + s_i * log2_coll1)
                if args.target - ood_bits <= args.max_ood_grind or s_i >= 8:
                    break
                s_i += 1

        # queries to hit target (query-challenge grinding shaves bits off)
        log2_per_q = math.log2(1 - theta)
        bound_to_one = (s_i > 0) or (i == 0 and args.l0_zerocheck_ood) \
            or regime_i == "udr"
        extra = 0.0 if bound_to_one else log2_L_int
        qg = args.query_grind
        t = math.ceil(max(args.target - qg + extra, 0.0) / -log2_per_q)
        query_bits = -(t * log2_per_q + extra)   # pre-grind, like pg/ood
        if t > n_i:
            print(f"  WARNING L{i}: t={t} > block length {n_i}", file=sys.stderr)

        # grinding needed so challenge-based terms reach target
        grind = max(0.0, args.target - pg_bits)
        if ood_bits is not None:
            grind = max(grind, args.target - ood_bits)
        grind = math.ceil(grind)

        total_queries += t
        total_cgrind += grind
        total_qgrind += qg
        total_ood_samples += s_i
        max_grind = max(max_grind, grind, qg)
        total_terms.append(-(pg_bits + grind))
        if ood_bits is not None:
            total_terms.append(-(ood_bits + grind))
        total_terms.append(-(query_bits + qg))

        # proof-size estimate for this level: each query opens one column
        # (2^k_ilv field elements) plus a Merkle path; t random queries share
        # the top ~log2(t) tree levels (pruned multiproof)
        leaf_bytes = (2 ** k_ilv) * 16
        path_hashes = max(0, log_block - math.ceil(math.log2(t))) if t > 0 else 0
        level_bytes = t * (leaf_bytes + path_hashes * 32) + s_i * 16
        total_bytes += level_bytes

        ood_str = f"{ood_bits:6.1f}" if ood_bits is not None else "     -"
        print(f"{i:>3} 2^-{rate_idx:<3} {log_cols:>5} 2^{k_ilv:<2} {log_block:>4} "
              f"2^{log2_L_int:<4.1f} {s_i:>2} {t:>4} {pg_bits:6.1f} {ood_str} "
              f"{query_bits:6.1f} {grind:>6} {qg:>6}")

    mx = max(total_terms)
    log2_total = mx + math.log2(sum(2 ** (x - mx) for x in total_terms))
    l0_note = " (+ L0 bound via zerocheck point, free)" if args.l0_zerocheck_ood else ""
    print(f"\ntotal queries: {total_queries}, "
          f"explicit OOD samples: {total_ood_samples}{l0_note}")
    print(f"challenge grinding (pg/ood): {total_cgrind} bits across levels; "
          f"query grinding: {total_qgrind} bits; "
          f"largest single grind: 2^{max_grind} hashes "
          f"(pg/ood/query columns are pre-grind)")
    # sumcheck messages: ~3 F128 values per folded variable, all levels
    sumcheck_bytes = (log_n) * 3 * 16
    total_bytes += sumcheck_bytes + (2 ** yr_log_n) * 16
    print(f"estimated proof size: {total_bytes/1024:.0f} KiB "
          f"(query openings + pruned Merkle paths + sumcheck + yr block)")
    print(f"TOTAL soundness error: 2^{log2_total:.1f}  "
          f"({-log2_total:.1f} bits of security)")


if __name__ == "__main__":
    main()
