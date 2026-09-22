# Curve IDs And Terp Use Cases

`proof_instance_verify` routes on the footer **`curve_id`**, not on `zkid`. `zkid` is only the app’s handle to a stored VK.

Your predictions are **mostly right**. The mismatches are: (1) **snarkjs is tooling** on **BN254 Groth16**, not a curve; (2) **Vesta** is the Pasta/Halo2-IPA *family*, not an automatic Orchard/Ironwood verifier; (3) **Stwo (M31)** is a first-class arm you did not list.

| `curve_id` | Name in code | Proving system | Your prediction | Terp use (honest) |
|------------|--------------|----------------|-----------------|-------------------|
| **0** | `Pasta` / Vesta | Halo2 **IPA** (Plonkish, no pairing setup) | Orchard / Ironwood verify | **Family is correct.** Pasta is the Zcash Orchard/Ironwood curve pair. On Terp this id is **generic Halo2-IPA**: Poseidon recovery, custom Plonkish circuits, any `#[cosmwasm_circuit]` on Vesta. Verifying a **mainnet Orchard spend** only works if you store *that* circuit’s VK. Ironwood is the same family, not a separate `curve_id`. |
| **1** | `VoteDelegation` | Halo2 IPA on Pasta | Private voting | **Correct.** vote-sdk ZKP #1 (delegation). |
| **2** | `VoteCommitment` | Halo2 IPA on Pasta | Coinholder polling | **Correct.** ZKP #2 (ballot / commitment). |
| **3** | `ShareReveal` | Halo2 IPA on Pasta | Tally / reveal | **Correct.** ZKP #3 (share reveal). Product: shielded coinholder polls via `terp-vsck` / vote-sdk, not a different curve from 0—**specialized circuits** on the same Pasta stack. |
| **4** | `Bn254` | Groth16 | *(you said snarkjs / zk-jwt)* | **snarkjs is the prover toolchain** for this id. Circom → snarkjs → ark Groth16 on the host. **Terp: `terp-zkjwt` OIDC/JWT membership** (and any other circom Groth16). Compact proofs, **circuit-specific trusted setup**. |
| **5** | `M31` | Stwo Circle STARK | *(not listed)* | **Lean consensus / recursion-shaped STARKs.** SSLE tickets, same-statement fold, valset / daily-key / withdraw AIRs in `lean-stwo-dummy`. No pairing setup. Dummy `DSTW` is **rejected**. |
| **6** | `Bn256Kzg` | Halo2-axiom **KZG / SHPLONK** | Personal / small-trusted-committee | **Half right.** Compact pairing proofs; trust is the **KZG ceremony**, not “a committee runs the app.” Terp wiring: **`zkjwt.passkey`** (feature `halo2-kzg`). Good for passkeys / small personal circuits where proof size matters more than “no setup.” |
| **7** | `FlockBlake3` | Flock R1CS + Ligerito (hash PIOP) | Hash-chain / snapshot archive attestation | **Right target.** Flock is Succinct’s **boolean/hash R1CS** (BLAKE3/SHA-2 encoders in `flock-prover`). Natural Terp uses: **pruned/archive snapshot validity**, historical hash-chain attestations, hash-heavy membership. Host must call `verify_ligerito` — the old 72-byte digest blob is **not** a proof. |

## How to pick one

| If the statement is… | Prefer | Why |
|----------------------|--------|-----|
| Hash / archive / “this snapshot commits to that history” | **7 Flock** | Hash R1CS + no pairing |
| Lean consensus object (SSLE, fold, valset) | **5 Stwo** | Circle STARK already in wasmvm host |
| Circom / snarkjs / Ethereum-shaped Groth16 (JWT) | **4 BN254** | Existing `terp-zkjwt` + snarkjs |
| Passkey / compact Halo2 with a setup | **6 KZG** | Pairing verify, small proofs |
| Zcash-like notes, Poseidon, IPA, no pairing setup | **0 Vesta** | Same assumptions as Orchard |
| Shielded vote (delegate / commit / reveal) | **1–3 Vote** | Dedicated vote-sdk circuits |

`prover_id` is orthogonal (`Plonkish`, `Groth16`, `Stwo`, `Flock`, …). Footer **pair** `(prover_id, curve_id)` is what the host dispatches on.

## What is *not* a curve

- **snarkjs** — JS Groth16 prover; proofs verify as **id 4**.
- **circom** — frontend for id 4.
- **Orchard / Ironwood** — Zcash protocols on **Pasta**; they would be **id 0** (or a future dedicated id) only with their VKs stored.
- **Dummy `FLCK` / `DSTW` blobs** — fail-closed; not use cases.

Demos: `terp-orch` (`circuit_interface` + `cw-zk-verify-demo`). Live Docker still uses ict-rs + wasmvm host hooks.
