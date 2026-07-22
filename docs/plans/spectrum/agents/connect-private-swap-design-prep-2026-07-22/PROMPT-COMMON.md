# Common prompt — design-prep for exact implementation

**Workspace:** `/Users/returniflost/abstract/terp-core`  
**Greenlight:** GO for **design-ready pack** (read + write DESIGN docs + HANDOFF interfaces).  
**Not GO:** large product implementation, mainnet claims, freeze amendments.  
**Execution:** Grok subagent — not Hermes workers.

## Required output structure (`DESIGN-<TRACK>.md`)

```markdown
# DESIGN-<TRACK>

## 0. Track charter
| Field | Value |
| Goal (one sentence) | |
| Closes gap ID | G1 / G2 / G3 / G4 |
| Depends on handoffs | (list) |
| Produces handoffs | (list) |

## 1. Current code reality (cite paths)
| Surface | Status | Path / command |

## 2. Target interface (freeze)
### Types / APIs (normative for implementers)
```rust
// exact signatures / field lists
```
### Wire format / env vars / HTTP if any

## 3. File touch list (implementation order)
| Order | Path | Change |
| 1 | ... | ... |

## 4. Acceptance tests (must be green to call done)
| ID | Layer | Command or assertion |
| T1 | pure / multi-test / shell | ... |

## 5. Fail-closed rules
| Condition | Expected error / exit |

## 6. Cross-track contracts
| Sibling | What this track needs from them | What this track promises |

## 7. Explicit non-claims / residual after this track
...

## 8. Ready-for-impl checklist
- [ ] Types named and field-complete
- [ ] Touch list has owners (file paths)
- [ ] Tests named (even if not written yet)
- [ ] HANDOFF section updated
```

## Shared ground truth

**Certified today:** `just demo-corridor-ict` = regtest observe + fixture Daemon mint + pure W0–W7 film.  
**cw-private-dex:** settle contract exists (`SettleSwap`, mock_verify dual-path); **not** wired into corridor harness.  
**Identity:** observe fields ↛ mint claim ↛ swap note (sequenced labels only).

## Tone

Engineering design freeze: tables, paths, signatures. No marketing. Prefer in-tree libs.
