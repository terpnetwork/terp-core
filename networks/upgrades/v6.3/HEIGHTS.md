# v6.3 then v6.4 heights

Governance submits one expedited plan, name `v6.3`. There is no v6.4
proposal. The v6.3 handler arms plan `v6.4` at the apply height plus
`NextUpgradeGap` (2). Cosmovisor directories are `v6.3` and `v6.4`.

## Halt for Friday 2026-10-16 10:00 UTC

`proposal.json` and `draft_proposal.json` use height `23893261`. v6.4 is
armed at `23893263`. Measured on the morocco-1 follower at height
`23838500`, time `2026-10-13T17:27:31.724629389Z`. The previous 2000 blocks
averaged 4.2429 seconds, which is 54761 blocks to 10:00 UTC. That is 34398
blocks past the 28800-block expedited floor. A 24-hour vote is 20363 blocks
at that rate.

Deposit `100000000000uterp` by `2026-10-15T10:00:00Z` so the 24-hour vote
ends as the halt arrives. The calculation record is `metadata.json`.

`plan.info` is `PENDING_FRIDAY_LINUX_TARBALL_CHECKSUMS` until this cut's
linux tarballs exist. Height `23833180` was for Tuesday 2026-10-13 10:00 UTC
and was already behind the follower at measurement.

## The number in the old draft is past

Height `23674923` was for Friday 2026-10-02 10:00 UTC. Height `23833180`
was for Tuesday 2026-10-13 10:00 UTC. The live draft is `23893261`.

## What has to exist before broadcast

1. CosmWasm, wasmvm, cw-orchestrator, abstract, dao-contracts, and terp-rs
   are clean checkouts of commits that are already on their remotes. A
   `path =` dependency is not a pin.
2. v6.4.0 linux tarball checksums are stamped into v6.3 `NextUpgradeInfo`
   from the tarballs that were just built (`-tags v64` first). No
   `file://` URL.
3. Those tarballs are the bytes operators will run. Tags `v6.3.0` and
   `v6.4.0` move only onto that commit, and only when asked.
4. A person picks a height that is still in the future after 24 hours of
   expedited voting plus the full expedited deposit
   `100000000000uterp`. Do not set it from the current RPC tip.

Expedited voting is 24 hours. Deposit that amount puts the proposal into
voting immediately. The chain's passed proposals on the last cut were
already applied (`current_plan` empty). This path is x/gov, not the DAO.

## Local proof before that height is written down

`tests/tsh/upgrade/v63.sh` on a snapshot must show `ibccallbacks` present,
`ibchooks` gone, v6.4 applied two blocks after v6.3, and the v6.4 plan
info carrying the stamped checksums. That run does not broadcast and does
not restart the house node.
