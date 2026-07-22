# compose_seams

Pure L0 fixture: cross-crate compose glue — `authorize_bridge_mint` → `SeamNoteOutV0` (+ rcm) → optional `SwapActionV0` sketch / product path.

```bash
cd docs/plans/spectrum/fixtures/compose_seams && cargo test
```

**Re-export surface** for harness: prefer this crate over path-importing bridge_auth + seam_note + private_dex separately for the product narrative.
