# private_dex_seams

Pure L0 fixture: private multi-pair DEX seam math + oracle-bound swap rules (SPEC Domain D). No halo2/MockProver.

```bash
cd docs/plans/spectrum/fixtures/private_dex_seams && cargo test
```

**Seeds:** E2E-10..13 (CP swap, oracle staleness/slippage, hard reject mint-from-oracle).
