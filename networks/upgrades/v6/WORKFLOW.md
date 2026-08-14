# v6 upgrade ops workflow (manual this cut)

Do these in order. Next time this becomes a named script in `scripts/release/`.

1. **Measure height** from `https://rpc.terp.network/status` + last 2000 blocks for mean `dt`.
2. **Pick wall time** (this cut: 2026-08-24 15:00 UTC) and convert with that `dt`. Round to a clean height (`22611000`).
3. **Write** `draft_proposal.json` height + `guide.md` table. Leave proposal id `TBD`.
4. **Build/tag** `v6.0.0`, publish the pack to `s3.terp.network/releases/terp-core/v6.0.0/` and the image to `containers.terp.network/terp-core:v6.0.0`. Fill `cosmovisor.json` checksums from that pack (do not invent them).
5. **Submit** gov proposal; paste id into `guide.md` and `versions.entry.json` `proposal`.
6. **Update** `networks/chain-registry/terpnetwork/` (the only in-repo copy), then PR upstream cosmos/chain-registry *after* the S3 objects and image are public. `recommended_version` stays on v5 until halt succeeds, then flip to v6.0.0.
7. **Validators** stage `$DAEMON_HOME/cosmovisor/upgrades/v6/bin/terpd` before halt.
8. **Post-halt** confirm `terpd q upgrade applied v6`.

Re-measure step 1 at T-48h. If `|new_height - 22611000| > 3000`, amend the proposal or tell operators the ETA slipped (height is authoritative, clock is not).
