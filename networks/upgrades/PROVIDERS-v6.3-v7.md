# Morocco-1 software upgrade: v6.3 then v6.4 (BLAKE3 non-IBC IAVL)

Public guides land with the Cosmovisor packs. Until then this is the operator
fact sheet. **Not** v6.1/v6.2 — those did not switch the hasher.

Two named upgrades, about two blocks apart. **This tree:** Cosmovisor
directories are plan names **`v6.3`** and **`v6.4`**, not git tags and not
`v7`. Governance submits **only** `v6.3`. The v6.3 binary arms `v6.4` at
apply+2. (`v7.0/WORKFLOW.md` is the older name for Upgrade B.)

| Order | Plan | Binary | What it does |
|-------|------|--------|----------------|
| 1 | `v6.3` | `terpd` **6.3.0** | Dual-store copy. Dest inner nodes **BLAKE3**. Live names SHA-256 until v6.4. IBC stays SHA-256 (hybrid lock). |
| 2 | `v6.4` | `terpd` **6.4.0** (`-tags v64`) | Keepers read dest (BLAKE3). Old SHA-256 copies leave CommitInfo. IBC unchanged. |

Heights: **TBD** after v6.1/v6.2 has applied. Do not reuse `23191300`.

Linux amd64/arm64 only. Pre-place **both** bins before the v6.3 height.

If Cosmovisor lacks `upgrades/v6.4/bin/terpd`, **your node stays halted while
the network moves on.**
