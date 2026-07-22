# STATUS — IMPL-DEST-SEAL (G4)

| Field | Value |
|-------|--------|
| **Track** | IMPL-DEST-SEAL / G4 |
| **Date** | 2026-07-22 |
| **Result** | **Green** (offline pure + shell + unit; full funded docker path not re-run this session) |

## Mission

Implement golden/live `dest_owner_binding` as the only allowed **product funded** dest seal; kill placeholder `"b"*64` invent on watch open / swap film continuous path.

## Changes

| Path | Change |
|------|--------|
| `crates/headstash/test-press/src/harness/zakura_local.rs` | `SealedDestV0`, `SealedDestSource`, `DestSealError`, `is_placeholder_owner_binding_hex`, `reject_placeholder_binding_hex`, `require_binding_hex_width`, `assert_dest_binding_equal`, `seal_funded_dest`; tests T2/T3/T9-shape |
| `crates/headstash/test-press/src/harness/mod.rs` | Re-export seal APIs |
| `crates/headstash/test-press/src/bin/corridor_ict_funded.rs` | Swap film uses `seal_funded_dest` → `CorridorScenario.dest_owner_binding`; receipt equality fail-closed; evidence prints `dest_seal` / source / rpc flags |
| `docs/plans/spectrum/e2e/corridor-ict-funded.sh` | `seal_funded_dest_shell` before watch; export `CORRIDOR_DEST_OWNER_BINDING`, `CORRIDOR_DEST_SEAL_SOURCE`, `ZAKURA_DEST_DISPLAY`, `CORRIDOR_DEST_RPC_READY`; watch payload uses sealed hex — **no** invent `"b"*64` |
| `docs/plans/spectrum/e2e/corridor-lab-smoke.sh` | Golden primary dest by default; residual placeholder only with `CORRIDOR_ALLOW_PLACEHOLDER_DEST=1` |
| `crates/terp-rs/tools/hash-market/src/corridor_deposits.rs` | Product `open_watch` rejects empty + placeholder unless `CORRIDOR_ALLOW_PLACEHOLDER_DEST=1` (force with `CORRIDOR_REJECT_PLACEHOLDER_DEST=1`); unit sample uses golden hex |
| `HANDOFF.md` | G4 status → implemented |

## Acceptance evidence

| ID | Result | Notes |
|----|--------|-------|
| **T1** | PASS | `cargo test -p zk-test-press --lib zakura_local --features 'interface,l0-seams'` — 9 tests |
| **T2** | PASS | `seal_funded_dest_primary_golden_when_env_unset` → `8b5cac11…` / `GoldenPrimary` |
| **T3** | PASS | `reject_placeholder_binding_hex_product_path` — empty, `b`/`a`/`c`/`0` * 64 |
| **T4** | PASS | `cashapp_w0_w7_with_golden_primary_dest` |
| **T5** | PASS | `zakura-local.sh golden` exit 0 |
| **T6** | PASS | `zakura-local.sh dest` → `owner_binding=8b5cac11…` |
| **T7** | PASS | `just demo-zakura-local-dest` exit 0 |
| **T8** | PASS (static + seal dry-run) | Script seal dry-run binds golden; watch payload uses `DEST_BIND` env (no invent assign); full docker funded not re-run |
| **T9** | PASS (pure) | `cashapp_w0_w7_with_seal_funded_dest` + binary wires `assert_dest_binding_equal` on receipt |
| **T10** | PASS (skip-clean) | Live RPC tests skip when Zakura down |
| **T11** | Residual (G1 join) | Equality helper ready; claim builder continuous assert lands with G1 |
| **T12** | Unchanged | UI offline golden constants (not touched) |

### Commands run

```text
cargo test -p zk-test-press --lib zakura_local --features 'interface,l0-seams' -- --nocapture
# → 9 passed

cargo test -p hash-market --lib corridor_deposits -- --nocapture
# → 12 passed (incl. rejects_placeholder + allow lab flag)

bash docs/plans/spectrum/e2e/zakura/zakura-local.sh golden
bash docs/plans/spectrum/e2e/zakura/zakura-local.sh dest
cd crates/headstash && just demo-zakura-local-dest

cargo check -p zk-test-press --bin corridor_ict_funded --features 'ict-daemon,l0-seams'
```

## Normative seal (shipped)

```text
owner_binding = SHA-256("terp-dest-binding-v0|" ‖ trim(dest_display))
primary: tmJymvcUCn1ctbghvTJpXBwHiMEB8P6wxNV
       → 8b5cac11e39905d56126a0c538b84ff8daa379d8009d4e8b121112479607f09b
```

Resolution order: `ZAKURA_DEST_ADDR` digest → else golden primary; optional RPC validate; fail closed on `CORRIDOR_REQUIRE_ZAKURA_RPC=1` only.

## Residuals

- Live ZEC broadcast / `z_send*` — out of scope (Phase F).
- Full `just demo-corridor-ict` docker ICT path not executed this session (binary checked; pure film green).
- G1 claim equality chain (`watch == claim.dest_commitment == mint == receipt`) — G1 owns claim builder; G4 exports seal + `assert_dest_binding_equal`.
- `CorridorScenario::default()` still synthetic for pure unit tests (by design); **funded** path calls `seal_funded_dest` / shell golden.
- Hash-market default now rejects placeholders on open_watch; lab residual must set `CORRIDOR_ALLOW_PLACEHOLDER_DEST=1` if intentionally testing fillers.

## Sibling promises

- **→ G1:** sealed 32B / 64-hex ready; field `dest_owner_binding` width frozen.
- **→ G2/G3:** single dest identity for owner_binding / receipt recheck.
- **↛** live ZEC egress ownership.
