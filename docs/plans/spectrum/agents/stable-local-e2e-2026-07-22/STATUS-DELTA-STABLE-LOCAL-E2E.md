# STATUS-DELTA — Stable local full multi-net e2e

| Field | Value |
|-------|--------|
| **Date** | 2026-07-22 |
| **Track** | META-DELTA (stable-local-e2e) |
| **Epic** | `docs/plans/spectrum/agents/stable-local-e2e-2026-07-22/` |
| **Bar (end goal)** | Stable, continuous, fully local multi-net **every time**: BTC regtest → observe → deposit mint → SEAM swap → SettleSwap → Option D burn → ZEC lab pay at **one** dest seal; re-run **2×**; later path to real ZEC open |
| **Evidence mode** | Design-intent + code/STATUS pack audit — **no** `STATUS-IMPL-P0-STABLE.md` / `STATUS-IMPL-P1-LAB-ZEC.md` at write time |
| **Honesty** | No mainnet claims; `mock_verify` lab default; simulated ZEC pay ≠ product host-pay |

---

## 0. Inputs read

| Source | Role |
|--------|------|
| `ORCHESTRATION.md` / `PROMPT-IMPL-P0-STABLE.md` / `PROMPT-IMPL-P1-LAB-ZEC.md` / this prompt | P0/P1/P2/META split + green definition |
| G1–G4 HANDOFF + `STATUS-IMPL-*` (connect-private-swap) | Landed continuous mint / SEAM / settle / dest seal |
| Option D HANDOFF + `STATUS-EPIC` + `STATUS-IMPL-{PURE,CW,ZAKURA-PAY,HARNESS-D}` | Burn → lab pay → dual receipts |
| Prior META: `STATUS-DELTA-SHIELDED-ZEC.md`, final-sprint `STATUS-META-REVIEW` / WASM green | Baseline honesty + funded mint proven once |
| Code spot-check | `corridor_ict_funded.rs`, `egress_d.rs`, `claim_from_deposit.rs`, `prepare-corridor-ict-wasm.sh`, justfile, shell |

**Re-read window:** folder still **only** prompts + ORCHESTRATION — IMPL STATUS not landed → matrix below is **predicted** from prompt scope vs current code, not post-impl measured green.

---

## 1. Stage matrix — goal vs after P0 vs after P1 vs residual

Legend: **G** green for bar · **P** partial / labeled residual · **M** missing · **H** human/host residual · **N** non-claim (out of local bar)

| Stage | End goal (local every time) | **Now** (pre P0/P1) | After **P0** (intent) | After **P0+P1** (intent) | Residual after P0+P1 |
|-------|----------------------------|---------------------|------------------------|---------------------------|----------------------|
| Docker + Terp image pin | Reproducible local-zk | P (image env; P2 docs) | P | P+P2 | Host Docker/image drift **H** |
| Ports / Zakura preflight | Start or labeled soft-skip | P (shell dest; live node residual) | **G**/soft | **G**/soft | macOS needs Linux `zakurad` **H** |
| BTC regtest observe | Funded UTXO + reporter | **G** (WASM-funded session; S2) | **G** | **G** | Race/timeouts under load **H** |
| **Deposit-backed mint** (ν continuous) | Claim from obs when present; happy only `CORRIDOR_ALLOW_HAPPY_FIXTURE=1` | **M/P** — helpers exist; binary still `configure_bridge_happy()` / hinge; shell does **not** export deposit env into mint | **G** (P0 #3) | **G** | Claim-inputs curl join flaky **H** |
| Single **dest seal** 32B | watch→claim→mint→settle→burn→zec equal | **P** — G4 golden on watch/shell; mint happy dest may diverge; Option D pins settle + `demo_zec_mint_seal_*` **display residual** | **G** (P0 #2 kill invent) | **G** | Operator env override mistakes **H** |
| Mint openings → settle | Continuous `MintEvidenceV0` / openings | **P** — evidence written after mint; settle suite green offline; dual type vs G2 `MintSpendEvidence` | **G** glue (P0 #4) | **G** | Optional pure-film dual noise **P** |
| SEAM swap / no synthetic NoteIn | G2 product path | **G** unit / film | **G** | **G** | — |
| CW **SettleSwap** | Daemon on funded path | **P** code + just; Docker settle **not agent-run** | **G** on full `egress-d` | **G** | Wasm/opt platform variance **H** |
| Option D **BridgeEgressBurn** | On-chain preferred; pure labeled OK | **P** — CW + multitest green; funded may **pure_record_lab** if stale headstash wasm | **G**/labeled (P0 wasm gate) | **G**/labeled | Stale artifact without prepare **H** |
| Dual receipts burn+zec | Fail-closed dest/ν | **G** unit + shell assert path | **G** | **G** | — |
| ZEC **lab inventory pay** real | `mode=lab_inventory_pay` + real `zec_txid` when wallet RPC | **P** default `*_simulated`; live degrade | P (preflight only) | **G** when RPC/wallet up (P1 #1) | No zcashd-compat wallet → stay simulated **P** |
| Open/confirm at sealed dest | validateaddress / balance-style | **P** skip-clean | P | **G**/skip-clean (P1 #2) | Shielded open tooling residual **P** |
| One-button full local | prepare → zakura → egress-d → assert | **M** (`demo-corridor-full-local` absent) | M | **G** (P1 #3) | Soft-skip branches must stay labeled **H** |
| Re-run **2×** same host | Definition of green | **M** (not proven this epic) | H (P0 may run once) | H unless session proves 2× | **Still blocks “every time”** until measured |
| Real ZEC **open** product path | Later | **N** | N | N (lab pay ≠ prod LC mint) | Phase open / Phase G **N** |
| `mock_verify=false` / mainnet | Out of epic | **N** | N | N | Production **N** |

```text
HUMAN END GOAL (local stable):
  observe → deposit-ν mint → SEAM swap → SettleSwap → Option D burn → ZEC at sealed dest
  · one seal · continuous ν · re-run 2× · labels honest

LANDED CODE (pre P0/P1):
  observe(regtest) + Daemon hinge mint + G1–G4 APIs + Option D pure/CW/lab_pay/HARNESS-D just
  · continuous deposit mint NOT default on binary path
  · full Docker settle/egress-d not meta-proven 2×
  · ZEC pay usually simulated

P0 TARGET: wire + harden continuous multi-net (seal, deposit default, evidence, wasm, preflight)
P1 TARGET: real lab pay when possible + one-button
P2 TARGET: pins/ports/USER-GUIDE honesty (parent)
```

---

## 2. Risks in the IMPL prompts (overclaim, races, seal split)

### P0 (`PROMPT-IMPL-P0-STABLE`)

| Risk | Severity | Detail |
|------|----------|--------|
| **Overclaim “full path works” without Docker evidence** | **High** | Prior G3/HARNESS-D correctly labeled Docker not agent-run. P0 STATUS must paste logs for `just demo-corridor-ict-egress-d` (not only mint-only) or residual remains. |
| **Seal split / `demo_zec_mint_seal_*`** | **High** | Code today invents residual display when settle `note_out.owner_binding` ≠ G4 golden (`egress_d::sealed_dest_for_option_d`). Root cause is often **hinge mint dest ≠ watch golden**. P0 must fix **mint/claim openings** to carry G4, not only rename residual. |
| **Deposit default vs happy silent** | **High** | `try_claim_from_env` + `BridgeL1World::from_deposit_claim` exist; `corridor_ict_funded` still calls **`configure_bridge_happy()` only**. G1 STATUS “prefer-deposit” is **ahead of binary wiring**. Shell must also export `CORRIDOR_DEPOSIT_TXID` / vout / amount from observation or default stays hinge. |
| **Evidence glue dual types** | Medium | G2 `MintSpendEvidence` vs G3 `MintEvidenceV0` — P0 “align” must specify single continuous handoff (convert or one SSOT) or risk reopen of synthetic openings. |
| **Wasm gate BridgeEgress** | Medium | `prepare-corridor-ict-wasm.sh` checks headstash **BridgeMint** + dex **SettleSwap**; **no** BridgeEgress surface gate yet. Without it, Option D silently `pure_record_lab` (labeled, but not full CW path). |
| **Zakura preflight races** | Medium | Soft-skip OK if labeled; race with Terp Docker ports / missing `ZAKURAD_BIN` on macOS → false “broken path” reports. |
| **Observe→mint race** | Medium | Reporter timeout paths exist; continuous claim needs stable claim-inputs after confs — fail-closed preferred over silent happy. |
| **Re-run 2× not in P0 prompt text** | Medium | Epic DoG includes re-run 2×; P0 mission list does not. Risk: green once, flake second run unowned. |

### P1 (`PROMPT-IMPL-P1-LAB-ZEC`)

| Risk | Severity | Detail |
|------|----------|--------|
| **Overclaim “real ZEC send”** | **High** | Zakura core ≠ full zcashd wallet; STATUS-ZAKURA-PAY already: degrade to simulated. Real `lab_inventory_pay` only when `sendtoaddress` / `z_sendmany` work — must fail-label otherwise. |
| **One-button green masking soft-skips** | **High** | `demo-corridor-full-local` must **fail** on dest mismatch / missing burn (prompt says so) — soft-skip only Zakura **start**, not burn or seal equality. |
| **Open/confirm overclaim** | Medium | validateaddress ≠ funds received; balance check may be empty even after pay until mine/index. Skip-clean required; no UI “ZEC received” without proof. |
| **P1 before P0 seal/deposit** | Medium | Real pay to wrong/residual dest is worse than simulated pay to continuous seal. Gate: P1 depends on P0 seal continuity. |
| **Parallel P2 docs lag** | Low–Med | Operators may run wrong just target if USER-GUIDE still placeholder (final-sprint condition). |

### Cross-prompt / process

| Risk | Detail |
|------|--------|
| **Stale STATUS as truth** | Final-sprint HARNESS FAIL table vs WASM green — same class of risk for P0/P1 STATUS. |
| **Mint-only residual sold as full e2e** | `demo-corridor-ict-egress-d-mint-only` must stay labeled residual; DoG explicitly **not** mint-only only. |

---

## 3. What still blocks “stable every time” **after** successful P0+P1

Even if P0 and P1 land to prompt letter, the following remain **honest blockers** for the end-goal phrase **“every time”**:

1. **Measured 2× re-run** on a real Docker host (image pin, wasm-opt, bitcoind, hash-market, Terp, optional Zakura) — not promised as completed work product unless STATUS pastes dual green logs.
2. **Host variance**: macOS Docker + Linux `zakurad`; binaryen/wasm-opt; dockerd resource races; port collisions (18232, hash-market 19090, ict grpc).
3. **Wallet fidelity for real pay**: without zcashd-compat wallet RPCs, P1 correctly stays `lab_inventory_pay_simulated` — **not** “ZEC at dest every time.”
4. **CW vs pure burn**: pure_record_lab remains acceptable residual if labeled; product narrative of on-chain egress needs prepare gate + redeploy every time.
5. **P2 packaging**: image/tag pins, ports preflight, USER-GUIDE second pass — without them “stable” is tribal knowledge.
6. **Lab policy forever on this bar**: `mock_verify=true`, provisional deposit ν domain, lab membership flags — production open / LC / mainnet remain **N**.
7. **Later real ZEC open** (shielded note open / product LC mint) — explicitly beyond P0+P1; Option D lab inventory only.

---

## 4. Recommendation for session gate

| Gate question | Recommendation |
|---------------|----------------|
| Claim **“G1–G4 + Option D code integrated (unit/suite)”** | **Yes** (prior STATUS green) |
| Claim **“stable local full multi-net every time”** | **No** until P0 Docker full path green **and** 2× re-run logged |
| Claim **“deposit ν continuous mint on funded path”** | **No** until binary leaves hinge-only and shell exports obs fields (P0 critical) |
| Claim **“single dest seal end-to-end”** | **No** while `demo_zec_mint_seal_*` residual can fire on happy-mint dest |
| Claim **“lab ZEC paid at sealed dest”** | **Simulated only** unless receipt `mode=lab_inventory_pay` + real txid; never product host-pay without burn |
| Claim **mainnet / mock_verify=false / LC mint** | **Never** this epic |

### Session GO / NO-GO

| Decision | When |
|----------|------|
| **NO-GO** for end-goal slogan now | Pre P0; deposit default unwired; Docker settle/egress-d not 2× proven |
| **CONDITIONAL GO (local continuous lab)** | After P0 STATUS with: full `demo-corridor-ict-egress-d` log, seal equality across artifacts, deposit mint when obs present, wasm BridgeEgress+SettleSwap gate, Zakura soft-skip labeled |
| **GO (local one-button lab incl. pay when RPC)** | After P1 + CONDITIONAL GO + one-button fails closed on dest/burn + honest pay mode label |
| **Still residual for “every time”** | 2× re-run + P2 pins/docs + host Zakura wallet |

### Suggested order

1. **P0 first** (seal + deposit default + evidence + wasm) — unblocks honesty of continuous corridor.  
2. **P1** only after seal continuous (pay destination meaningful).  
3. **P2** parallel OK for docs/ports; do not block P0 code.  
4. Human/ops: pin `terpnetwork/terp-core:local-zk`, prepare wasm-settle, prove **2×**.

### Explicit non-claims (META)

- This file does **not** assert P0/P1 implementation complete.  
- Does **not** re-run Docker e2e.  
- Does **not** authorize mainnet money language.  
- Simulated ZEC receipt is **lab film** unless mode upgrades with real wallet RPC.

---

## 5. Top residuals (board shortlist)

1. **Deposit-backed mint not wired on `corridor_ict_funded`** (still hinge `configure_bridge_happy`).  
2. **Seal continuity** (kill `demo_zec_mint_seal_*` invent when G4/env set — fix mint dest, not only Option D pin).  
3. **Full Docker `demo-corridor-ict-egress-d` + 2× re-run unproven** this session.  
4. **Wasm prepare lacks BridgeEgress gate** → pure_record_lab risk.  
5. **Real `lab_inventory_pay` host-dependent** (Zakura wallet RPCs).  
6. **No one-button** `demo-corridor-full-local` yet (P1).  
7. **P2 USER-GUIDE / port-image pin honesty** still lagging product narrative.  
8. **Production open / mock_verify=false** out of scope.

---

## Signature

```text
META-DELTA stable-local-e2e: design-intent (STATUS-IMPL-P0/P1 absent)
End goal: continuous multi-net + single seal + ZEC lab pay every time (2×)
P0 intent closes: observe path, seal, deposit default, evidence glue, wasm, zakura preflight
P1 intent closes: real lab pay when RPC + one-button
Blocks after P0+P1: measured 2×, host/wallet variance, P2 packaging, prod open
Do not claim "stable every time" or "send ZEC product" from prompts alone
```


## 0.1 Post-impl refresh (2026-07-22)

| Track | Status | Evidence |
|-------|--------|----------|
| **P0 STABLE** | **Landed** | `STATUS-IMPL-P0-STABLE.md` — full `demo-corridor-ict-egress-d` green once; single seal; deposit_claim; wasm gates; Zakura preflight soft-skip |
| **P1 LAB-ZEC** | **Landed** | `STATUS-IMPL-P1-LAB-ZEC.md` — real pay path when wallet RPC; open confirm; `just demo-corridor-full-local` |
| **P2 PARENT** | **Landed** | `STATUS-P2-PARENT.md` — preflight + MACHINE-PREREQS + USER-GUIDE |

### Session gate update

| Claim | Verdict |
|-------|---------|
| Continuous local multi-net structure | **GO** (P0 full path green once) |
| Stable *every time* / 2× re-run | **Residual** — not yet measured |
| Real ZEC at dest (non-simulated) | **CONDITIONAL** — needs ZAKURAD + wallet RPC |
| Mainnet | **NO-GO** |

### Top residuals after P0+P1+P2

1. 2× re-run / flake measurement  
2. Live `lab_inventory_pay` (wallet on Zakura)  
3. Optional CI gate for `demo-corridor-full-local`  
4. Production LC / mainnet (out of epic)
