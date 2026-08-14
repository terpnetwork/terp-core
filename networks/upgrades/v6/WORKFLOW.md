# v6 upgrade ops workflow (manual this cut)

Do these in order. Next time this becomes a named script in `scripts/release/`.

1. **Measure height** from `https://rpc.terp.network/status` + last 2000 blocks for mean `dt`.
2. **Pick wall time** and convert with that `dt`. Floor is **+7 days**. This cut stays at coordinated height **`22611000`** (~2026-08-24 15:00 UTC; remasure 2026-08-14 22:16 UTC = **9.70 d** at 3.5763 s/block).
3. **Write** `draft_proposal.json` height + `guide.md` table. Leave proposal id `TBD`. Do **not** broadcast.
4. **Curate** the pack under `build/release/v6.0.0/` (binaries, `source.tar.gz`, `cosmovisor.json`, checksums). Intended bucket layout after a later upload (not this step):
   - `s3.terp.network/releases/terp-core/v6.0.0/`
   - `containers.terp.network/terp-core:v6.0.0`
   Fill `cosmovisor.json` checksums from that pack (do not invent them). **Do not upload or tag until asked.**
5. **Submit** gov proposal only when asked; paste id into `guide.md` and `versions.entry.json` `proposal`.
6. **Update** `networks/chain-registry/terpnetwork/` (the only in-repo copy), then PR upstream cosmos/chain-registry *after* the S3 objects and image are public. `recommended_version` stays on v5 until halt succeeds, then flip to v6.0.0.
7. **Validators** stage `$DAEMON_HOME/cosmovisor/upgrades/v6/bin/terpd` before halt.
8. **Post-halt** confirm `terpd q upgrade applied v6`.

Re-measure step 1 at T-48h. If remaining time drops under **7 days**, or `|new_height - 22611000| > 3000`, amend the draft (do not broadcast a stale height). Height is authoritative; clock is not.

## Prepare-only upload list (do not run)

Objects to place later at `releases/terp-core/v6.0.0/` on s3.terp.network:

- `terpd-6.0.0-darwin-arm64.tar.gz`
- `terpd-6.0.0-linux-amd64.tar.gz`
- `terpd-6.0.0-linux-arm64.tar.gz`
- `source.tar.gz` + `source.tar.gz.sha256`
- `binaries.json` `manifest.json` `sha256sum.txt` `CHECKSUMS.txt` `cosmovisor.json`

Image later: `containers.terp.network/terp-core:v6.0.0`.
