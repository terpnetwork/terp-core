# PROMPT — IMPLEMENT G4 DEST-SEAL

Workspace: `/Users/returniflost/abstract/terp-core`

## Read first

1. `IMPL-ORCHESTRATION.md`
2. `HANDOFF.md` § G4
3. `DESIGN-DEST-SEAL.md`
4. `docs/plans/spectrum/e2e/zakura/golden-dest-binding.json`

## Mission

**Implement** golden/live dest on **funded** path; kill placeholder `"b"*64` as product dest seal.

### Required code

1. `corridor-ict-funded.sh` (and any watch open): use primary golden binding or `ZAKURA_DEST_ADDR` / `CORRIDOR_DEST_OWNER_BINDING`.
2. Reject placeholders on product funded path (helper in shell and/or Rust).
3. `corridor_ict_funded` / W0–W7 corridor scenario: `owner_binding` = primary golden when continuous path.
4. Export env: `CORRIDOR_DEST_OWNER_BINDING`, `CORRIDOR_DEST_SEAL_SOURCE`.
5. Optional: soft RPC validate when Zakura up; skip-clean when not.
6. Tests: placeholder reject; golden equality with `zakura_local` primary.

### Acceptance

- `just demo-zakura-local-dest` still green (offline)
- Script/unit proof that funded watch dest ≠ all-`b` placeholder

### Out of scope

Live ZEC broadcast, claim builder body (G1 consumes dest only).

## Write

`STATUS-IMPL-DEST-SEAL.md` + HANDOFF G4 status update.
