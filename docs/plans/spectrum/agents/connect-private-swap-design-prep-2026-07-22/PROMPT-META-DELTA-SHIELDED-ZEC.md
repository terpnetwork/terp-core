# PROMPT — META: deltas to full pipeline + send shielded ZEC

Workspace: `/Users/returniflost/abstract/terp-core`

## Mission

After (or while) IMPL tracks run, produce an **honest delta matrix** between:

**A.** Session end-goal stated by human: *full pipeline integration so we can send shielded ZEC*  
**B.** What G1–G4 designs + implementations actually deliver  
**C.** What remains after this wave  

## Read

- All `DESIGN-*.md`, `HANDOFF.md`, `IMPL-ORCHESTRATION.md`
- Any `STATUS-IMPL-*.md` that exist
- `STATUS-GAP-SYNTHESIS.md` Phases E–F–G
- Zakura / cashapp corridor harness (W7 open film)
- `cw-private-dex` README (no post_swap yet)

## Write `STATUS-DELTA-SHIELDED-ZEC.md`

Required sections:

### 1. Pipeline stages table

| Stage | Required for shielded ZEC send | G1–G4 wave | Status after impl | Delta |
| BTC deposit observe | yes | partial | | |
| Continuous mint claim | yes | G1 | | |
| Dest seal preauth | yes | G4 | | |
| Private swap of mint note | yes | G2 | | |
| On-chain settle | yes (product) | G3 | | |
| Post-swap Action / unshield | maybe | no | | |
| Shielded ZEC note out | yes | partial narrative | | |
| Live open / broadcast to dest | **yes for “send”** | **out of G1–G4** | | |
| mock_verify=false / LC | production | no | | |

### 2. Definition of done — three bars

| Bar | Meaning | This wave? |
| continuous local multi-net (identity+settle film/chain) | G1–G4 | target |
| Lab shielded ZEC open (local node, preauth dest) | Phase F | **identify residual** |
| Production send shielded ZEC | mainnet + real proofs | **non-claim** |

### 3. Minimal extra work to claim “lab send shielded ZEC”

Ordered checklist (paths, owners). Be concrete.

### 4. Delegation prompt review

Critique the four IMPL prompts: missing deps, race risks, overclaim risk. Suggest wording fixes.

### 5. Recommendation

What human should gate as “session complete” vs “next session”.

Tone: engineering honesty. No marketing. No freeze amendments.
