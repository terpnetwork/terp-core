# End-user guide — Cash App → Private Bridge → ZEC

| Field | Value |
|-------|--------|
| **Product** | Private Bridge (`PrivateCorridor` module in dao-dao-ui) |
| **Audience** | End users of a deployed Private Bridge corridor; operators reading for UX honesty |
| **Status** | **Mainnet-funded-ready composition** — workflow shape matches production; local multi-net proves fidelity; **local success ≠ mainnet money** |
| **Date** | 2026-07-22 |
| **Engineering SSOT** | [`DEMO-CASHAPP-ZEC-CORRIDOR.md`](./DEMO-CASHAPP-ZEC-CORRIDOR.md) · freezes [`DESIGN-DECISIONS-CORRIDOR-ACCEPTED-2026-07-20.md`](./DESIGN-DECISIONS-CORRIDOR-ACCEPTED-2026-07-20.md) |
| **Operator path** | [`websites/dao-dao-ui/.../PrivateCorridor/OPERATOR.md`](../../../websites/dao-dao-ui/packages/stateful/modules/modules/PrivateCorridor/OPERATOR.md) |
| **Sprint bar** | [`agents/final-sprint-2026-07-22/ORCHESTRATION.md`](./agents/final-sprint-2026-07-22/ORCHESTRATION.md) · [`FEEDBACK-RAISED-BAR.md`](./agents/final-sprint-2026-07-22/FEEDBACK-RAISED-BAR.md) |

This document is the **user-facing composition** of how the product works: what you commit to **before** sending money, what the bridge may and may not do with your funds, and how **`lab_simulated` / `ict_local_funded` / `production`** deployments differ. Labels below must match the deployment you are using.

| Term | Meaning (used below) |
|------|----------------------|
| `domain_bind` | Intent integrity under `terp-cashapp-intent-v0` (not Domain B asset-map ids) |
| `bound_only` | Oracle supplies mid/bounds for swap policy; **never** mints |
| `fail-closed` | On re-verify or policy fail, stop as failure — do not continue as success |

---

## 1. What this product is

**Private Bridge** takes a **fresh Bitcoin deposit** (Cash App or any wallet that can send BTC to a QR address) through:

1. **Pre-authorization** of where ZEC can go and under what swap bounds (**intent first**)  
2. **Observation** that the BTC deposit actually landed  
3. **Private mint** of a note on Terp (`SeamNoteOutV0` via `cw-headstash` `BridgeMintNote`)  
4. **Oracle-bound private swap** toward ZEC (`bound_only` — the oracle never mints)  
5. **Payout / open** only to the destination you locked in at the start  

You do **not** reuse a hot wallet identity for the deposit address. The browser generates a **new** HD deposit wallet (SelfRelay-style 24-word mnemonic → P2WPKH receive address) so the funding rail is not your everyday Cash App identity on-chain.

```text
Cash App / wallet  →  fund FRESH BTC address
                   →  intent already sealed (dest + min out / slip + domain_bind)
                   →  private bridge mint (SeamNoteOutV0)
                   →  private swap BTC-note → ZEC-note (oracle bound_only)
                   →  only pre-authorized dest can open / receive
```

That spine is the **same workflow shape** mainnet money will use. Profiles change **where** networks live (synthetic / local test nets / mainnet) and **how strict** re-verify and mint proof policy are — not a separate lab-only product fork.

---

## 2. Three deployment profiles (read the banner)

Do **not** collapse these. UI and operators must keep them distinct.

| Profile | Purpose | Mint | Observe | What success means |
|---------|---------|------|---------|-------------------|
| **`lab_simulated`** | Explicit lab mode; CI / training | Mock / `mock_verify` OK | Synthetic observe OK | Lab success only — **not** mainnet settlement |
| **`ict_local_funded`** / **testnet** | **Fidelity gate** before mainnet money | **Real local (or testnet) chain** `BridgeMintNote` (ict-rs Terp + cw-orch Daemon) | **Regtest/signet** BTC (or local Esplora/Electrum) → `corridor-btc-reporter` → hash-market watches | Same **workflow** as production on **test money / local nets** — still **not** mainnet settlement |
| **`production`** / mainnet | Live ops after ops keys, liquidity, legal | Proof policy per deployment (stage `mock_verify` off when ready) | Production index (Fulcrum / self-hosted / approved light index) | Mainnet rails when that deployment is explicitly enabled — still subject to Cash App freezes and Terp/ZEC egress policy |

### Banner language (honest)

| You see | Treat as |
|---------|----------|
| **“Lab mode — not production”** | `lab_simulated` only (D5). Every “success” is lab-controlled — not mainnet money. |
| **Local / test network** (or equivalent funded-local copy) | `ict_local_funded` or public testnet. Real local chain txs may exist; **do not** claim Cash App mainnet → Zcash mainnet settlement. |
| **Production / LC live** (no lab banner) | Production-shaped path: re-verify **fail-closed**; real deposit observation. Confirm with the operator whether **this** deployment is mainnet BTC/ZEC or still testnet. |

**Hard rule:** local or testnet success is a **proof of workflow fidelity**, not a receipt for mainnet money.

---

## 3. What “mainnet-funded-ready” means

| Ready means | Still ops / external (not “code green” alone) |
|-------------|-----------------------------------------------|
| Intent → fund → observe → reverify → **chain** mint → oracle-bound (`bound_only`) swap → preauth dest is one continuous path | Mainnet keys, liquidity, legal, Cash App policy |
| Lab floor (`just demo-corridor-lab`, pure I1–I6) stays green | Mainnet broadcast of user BTC/ZEC in CI (never required for green) |
| `ict_local_funded` proves **live** `BridgeMintNote` on a fresh local Terp net (ict-rs), not Mock-only soft-skip | Full Halo2 browser circuits if Mock/proof policy still stages lab mints |
| Re-verify **fail-closed** on production-shaped modes | Cash App can freeze **their** rail independently of Terp |
| Stage ownership matches **code primitives** below (expiry, dest binding, double-mint, deposit HD) | Optional `recovery_owner_binding` / timeout vault if not yet deployed on that corridor |

Sprint proof vehicle: **full local multi-network simulation on fresh testnets via `ict-rs`** (+ pure/Mock as CI floor). See §7.

---

## 4. Before you send anything — the deposit intent

**Authorization happens at intent time, not after the BTC is spent.**  
Before (or with) funding the deposit address, the product seals a **DepositIntent** packet. Changing destination or swap policy after you fund requires a **new intent**; the old deposit cannot be redirected.

### 4.1 What you lock in

| You choose | Locked as | Why it matters |
|------------|-----------|----------------|
| **ZEC destination** | `dest_owner_binding` (opaque handle from your UA / transparent dest / Zakura demo dest; domain `terp-dest-binding-v0`) | Mint and swap **must** re-check this. A different recipient is **rejected**. |
| **Minimum ZEC out** | `min_out_value` | Swap cannot complete below this floor. |
| **Max slippage** | `max_slippage_bps` (optional) | Policy vs oracle mid (e.g. mid × (1 − slip)). |
| **Corridor + assets** | corridor id, BTC in / ZEC out asset ids | Wrong corridor or asset map = reject. |
| **Expiry** | `expiry` | Late mints against an expired intent = **reject** (I3). |
| **Intent integrity** | `domain_bind` under `terp-cashapp-intent-v0` | Intent hash domain; not Domain B asset-map ids (D2). |

Technical field set: DEMO §3 `DepositIntentV0`.  
Display strings (truncated UA, labels) are **hints only** — authority is the binding and the signed / hashed intent.

### 4.2 Happy path (what you do)

1. Open **Private Bridge** on the DAO that hosts the corridor.  
2. **Step: ZEC dest** — paste a unified address / transparent dest, or use **local Zakura demo dest** when the operator enabled D6 local Zakura. Confirm the binding.  
3. **Step: rate policy** — set minimum out and optional max slippage for the `BTC-ZEC` market.  
4. **Step: deposit wallet** — generate the browser HD wallet; **back up the mnemonic** if you need recovery of that deposit key (the bridge does not hold your Cash App password).  
5. **Create proof + QR** — intent is sealed; you get a P2WPKH QR and an auth / intent id.  
6. **Fund** that address from Cash App (or lab faucet / lab “publish observed” / regtest fund depending on profile).  
7. **Wait for observe → reverify → mint → swap** status.  
   - `lab_simulated`: synthetic observe OK (lab mode only).  
   - `ict_local_funded` / `production` / `lc_live`: **fail-closed** UI re-verify of the BTC observation (override only if operator documents an explicit exception).  
8. **Receipt** — confirm destination binding matches what you sealed; clear or store mnemonic per your risk model.

### 4.3 What the product must refuse

| Situation | Expected outcome | Code / policy anchor |
|-----------|------------------|----------------------|
| Swap or open to a **different** dest than the intent | **Reject** | `dest_owner_binding` re-check (I1) |
| Oracle mid below your floor / slip exceeded | **Reject** | `min_out_value` / `max_slippage_bps` (I2) |
| Intent **expired** | **Reject** | `expiry` (I3) |
| Second mint for the same burn / intent | **Reject** | `IsBridgeMinted` / nullifier (I4) |
| Oracle mid **missing or stale** | **Reject** (no silent mint) | oracle `bound_only` (I6, D7) |
| Re-verify fail on production-shaped mode | **Fail-closed** (do not continue as success) | UI reverify policy |

These rules are the product meaning of “authorized by the initial transfer”: the **first** transfer funds an address that is already bound to a **fixed** designation and **fixed** swap bounds.

---

## 5. Funds safety and loss mitigation (code-backed)

This section maps **stage ownership** to **primitives that exist in intent, contract, and client code**. Residuals are called out — not papered over as guarantees.

### 5.1 Stage ownership (mental model + primitives)

| Stage | Who controls the economic claim | Primitive / surface | If the stage fails |
|-------|----------------------------------|---------------------|--------------------|
| **Pre-fund** | You still hold BTC in Cash App / your wallet | — | Cancel by not sending |
| **Deposit address funded, not yet observed** | You control the **deposit HD keys** (browser mnemonic from UI `browserWallet`) | Fresh P2WPKH; user-held seed | You can still **sweep the UTXO yourself** if the corridor never observes |
| **Observed → mint pending** | Claim is bound to **intent** | `dest_owner_binding`, amounts / min deposit floor, `expiry`, `domain_bind` | Operators coordinate observation; they must **not** redirect dest. Expired intent → mint **reject** |
| **Minted private note** | Note ownership follows intent owner binding | `BridgeMintNote` + note `owner_binding`; `IsBridgeMinted` blocks double seize of same ν | Wrong dest open = reject |
| **Swap under oracle bounds** | Same binding + min_out / slip | Oracle mid/bounds only (`bound_only`; never mints) | Bad mid / slip → fail-closed |
| **Timeout / stuck after observe** | Prefer **pre-declared** recovery role if configured | Optional `recovery_owner_binding` (or dest-domain recovery role) when live on that deploy | If **not** configured: ops incident using **intent id + deposit HD** — **no** open admin hot-wallet seize, **no** Cash App clawback claim |

### 5.2 Explicit non-guarantees (honest product copy)

Until a **named deployment** documents otherwise:

- **No Cash App private API** — funding is a normal BTC send to the QR; Cash App can freeze or reverse **their** side independently of Terp.  
- **`lab_simulated`** may **not** move real BTC or real ZEC; mint may use `mock_verify`.  
- **`ict_local_funded` / testnet** can run real local-chain mint and regtest/signet observe; that still **≠ mainnet settlement**.  
- **Mainnet ZEC egress** and full light-client proof mint may be staged or mock-verified depending on deploy policy — read the corridor’s ops notes.  
- Notify plane (hash-market watches / SSE) is **coordination**; production-shaped UI must **re-verify** against a BTC index, not trust a single HTTP event alone.  
- **Oracle never mints** — `bound_only` mid/bounds for the private swap policy (D7).  
- Operators do **not** get an unbounded hot-wallet redirect of a funded intent.

### 5.3 What you should keep

- Intent id / auth link material for support and host automation.  
- Deposit **mnemonic** until the deposit is fully consumed or you have swept remaining UTXOs.  
- Confirmed **dest binding** screenshot or copy from the receipt step.  
- Txid of the BTC fund (for re-verify and support).

### 5.4 What operators must not do (user trust)

- Redirect a funded intent to a **new** destination without a new intent and a new deposit.  
- Treat lab or local-test success banners as mainnet settlement.  
- Seize corridor funds into an operator hot wallet outside a **pre-declared** recovery binding / timeout policy.  
- Soft-skip chain mint on the **funded** profile and still claim mainnet-funded readiness.

---

## 6. Screens and steps (UI map)

Aligned with the PrivateCorridor wizard (names may vary slightly in UI chrome):

| Step | User action | Product effect |
|------|-------------|----------------|
| 1. ZEC dest | Paste UA / t-addr or “Use local Zakura demo dest” | Computes `owner_binding` (domain `terp-dest-binding-v0`) |
| 2. Rate policy | Min out, max slip, market id | Seals oracle-bound policy into intent |
| 3. Deposit wallet | Generate HD / show QR | Fresh P2WPKH; client proof materials |
| 4. Fund + auth | Send BTC or lab publish observed | Watch registration; SSE / poll for `deposit_observed` |
| 5. Status | Wait; re-verify on production-shaped modes | Mint + swap automation; fail-closed on bounds / reverify fail |
| 6. Receipt | Confirm binding; clear mnemonic | Terminal UX |

Operator bootstrap (hash-market lab, Zakura local, mint-after-observe): see **OPERATOR.md**.

**Publish surface:** spectrum path above; in-module “How it works” link to this guide is preferred when the UI track lands it (site publish later OK).

---

## 7. Local proof path (ict-rs multi-net) — not mainnet money

Engineering proves the **mainnet workflow shape** by running it on **fresh local test networks**, not by spending mainnet in CI.

### 7.1 Lab floor (always)

Fast CI / training path — **`lab_simulated`**:

```bash
# From crates/headstash or docs/plans/spectrum:
just demo-corridor-lab

# Pieces:
just demo-corridor-lab-smoke
just demo-corridor-mint-after-observe
just demo-zakura-local-dest   # D6 dest binding (optional for lab floor)
just demo-e2e-l0              # pure seams
just demo-e2e-l1              # Mock BridgeMintNote (not funded-profile exit alone)
```

Details: [`e2e/README.md`](./e2e/README.md) · [`e2e/CORRIDOR-LAB-STATUS.md`](./e2e/CORRIDOR-LAB-STATUS.md) · [`e2e/ZAKURA-LOCAL.md`](./e2e/ZAKURA-LOCAL.md).

### 7.2 Funded local profile (sprint gate)

**`ict_local_funded`** should run approximately:

```text
ict-rs fresh Terp (+ required sidecars)
  → deploy cw-headstash bridge corridor
  → seal DepositIntentV0 (dest + bounds + expiry)
  → fund / observe on BTC regtest or signet (reporter → /corridor/observations)
  → reverify-shaped gates
  → live-chain BridgeMintNote (tx hash / events; IsBridgeMinted)
  → oracle-bound swap (bound_only)
  → preauth dest binding check (Zakura local / golden terp-dest-binding-v0)
```

**Commands (`ict_local_funded` — not mainnet settlement):**

| Target | Role | Notes |
|--------|------|--------|
| `just demo-corridor-ict` (from `crates/headstash`) | Observe + Daemon `BridgeMintNote` | Default `mock_verify=true` (funded-local label) |
| `just demo-corridor-ict-settle` | + on-chain private `SettleSwap` | Needs dual wasm (`cw_private_dex`) |
| `just demo-corridor-ict-egress-d` | + **Option D** Terp burn → lab ZEC pay | Full local multi-net spine; ZEC pay may be **simulated** until Zakura wallet live |
| `just demo-corridor-full-local` | One-button when landed | prepare + Zakura best-effort + egress-d |
| Preflight | Machine gate | `bash docs/plans/spectrum/e2e/preflight-corridor-local.sh` |
| Prereqs | Docker / ports / images | [`e2e/MACHINE-PREREQS-LOCAL-E2E.md`](./e2e/MACHINE-PREREQS-LOCAL-E2E.md) |

**Stable local bar (engineering):** regtest observe → deposit-backed mint → note-coupled settle → Option D egress → sealed dest continuity. Labels: `mock_verify` lab OK; `lab_inventory_pay_simulated` ≠ mainnet ZEC.

See harness STATUS, [STATUS-WASM-FUNDED-GREEN](./agents/final-sprint-2026-07-22/STATUS-WASM-FUNDED-GREEN.md), and [Option D decision](./DESIGN-DECISIONS-ZEC-EGRESS-OPTION-D-ACCEPTED-2026-07-22.md).

### 7.3 What local proof does *not* claim

- Local/testnet success **≠** mainnet BTC or ZEC settlement  
- Synthetic lab txids (`lab-…`) **≠** funded observe path  
- Mock-only mint **≠** funded-profile exit  
- Paste-first Zakura dest **without** a runnable local node in the funded stack is UX-primary but incomplete fidelity for S5  
- **`lab_inventory_pay_simulated`** **≠** funds on Zcash consensus (Option D structure may still be green)  
- **`mock_verify=true`** **≠** production LC / real membership proofs

---

## 8. FAQ

**Is this the Headstash airdrop claim?**  
No. Private Bridge is a **separate** module. Airdrop claim is a different product surface. Demo mint is **bridge mint**, not airdrop claim (D3).

**Can I change my ZEC address after I already sent BTC?**  
Not for that deposit. Create a **new** intent (and new deposit address) if you need a new destination.

**Does the price oracle send me coins?**  
No. Oracle (e.g. hash-market Connect) only supplies **bounds** for the private swap. Mint is **`cw-headstash`** only.

**What if Cash App is slow or the deposit never shows?**  
Keep the deposit mnemonic. If the address was funded on-chain but the corridor never observed, you may still control the UTXO. Contact the corridor operator with txid + intent id. Recovery is **deposit HD + intent binding + optional recovery binding** — not an open operator seize.

**Why a new wallet every time?**  
So the deposit is **fresh** and not mixed with your everyday Cash App or exchange hot identity. Privacy and attribution separation.

**If the local ict demo worked, is mainnet safe?**  
It means the **workflow shape** was exercised with real local-chain mint and non-synthetic observe (when the funded profile is green). It does **not** by itself move or prove mainnet funds, liquidity, or Cash App behavior.

**Lab vs funded local — which banner?**  
Lab: “Lab mode — not production.” Funded local: not that banner — use truthful local/test-network language. Production: no lab banner; re-verify fail-closed.

---

## 9. Related engineering docs

| Doc | Role |
|-----|------|
| [DEMO-CASHAPP-ZEC-CORRIDOR.md](./DEMO-CASHAPP-ZEC-CORRIDOR.md) | Product corridor SPEC |
| [DESIGN-DECISIONS-CORRIDOR-ACCEPTED-2026-07-20.md](./DESIGN-DECISIONS-CORRIDOR-ACCEPTED-2026-07-20.md) | D1–D7 freezes |
| [FLOW-private-bridge-auth.md](./FLOW-private-bridge-auth.md) | Full compose auth flow |
| [e2e/](./e2e/) | Lab host, smoke, Zakura local |
| PrivateCorridor [`OPERATOR.md`](../../../websites/dao-dao-ui/packages/stateful/modules/modules/PrivateCorridor/OPERATOR.md) | Operator runbook + lab host path |
| [agents/final-sprint-2026-07-22/ORCHESTRATION.md](./agents/final-sprint-2026-07-22/ORCHESTRATION.md) | Sprint DoD (S0–S8), profiles |
| [agents/final-sprint-2026-07-22/FEEDBACK-RAISED-BAR.md](./agents/final-sprint-2026-07-22/FEEDBACK-RAISED-BAR.md) | Raised bar + recovery primitives |

---

## 10. Documentation workstream (maintainers of *this* guide)

When shipping or revising end-user copy:

1. Keep **three profiles** honest — `lab_simulated` is explicit lab mode (CI/training), not the production product story.  
2. Lead with **intent = dest + swap bounds + `domain_bind` before fund**.  
3. Stage ownership must cite **code primitives** (expiry, dest binding, double-mint, deposit HD); residual only what code truly lacks.  
4. Point at **ict-rs local multi-net** (`ict_local_funded`) as the fidelity proof; never claim local = mainnet money.  
5. Keep §7 command names and `mock_verify` deploy notes aligned with harness / WASM STATUS.  
6. Prefer in-module “How it works” → this path; public site later OK.  

**Hermes kanban:** documentation task for this demo attaches:

`docs/plans/spectrum/USER-GUIDE-CASHAPP-PRIVATE-BRIDGE.md`
