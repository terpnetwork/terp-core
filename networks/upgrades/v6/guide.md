# Terp-Core v6 — SDK 0.54 / IBC-Go 11.1

| | |
|---|---|
| Chain-id | `morocco-1` |
| Plan name (handler) | **`v6`** |
| Binary tag | [`v6.0.0`](https://github.com/terpnetwork/terp-core/releases/tag/v6.0.0) *(fill when tagged)* |
| Upgrade height | **`22611000`** |
| Target wall time | **2026-08-24 15:00 UTC** (10 days from 2026-08-14) |
| Proposal | [ping.pub](https://www.ping.pub/terp/gov) — ID **TBD** until submitted |
| Countdown | [block 22611000](https://www.ping.pub/terp/block/22611000) |

## Schedule (measured, not guessed)

Snapshot taken **2026-08-13 06:44 UTC**:

- Live height: `22336990`
- Mean block time (last 2000 blocks): **~3.5785 s**
- +11.34 d → ~`22610879`
- **Rounded coordinated height: `22611000`**

Re-measure 48 hours before submitting the proposal. If average block time drifts by 0.1 s, height moves by ~±8k blocks over 11 days. Adjust `draft_proposal.json` before broadcast.

This is a **breaking** cut: Cosmos SDK **v0.54.3**, ibc-go **v11.1/v11.2**, official **08-wasm v11.1.0**, CosmWasm/wasmd **0.70** + local **zk-wasmvm**. `x/group` and in-tree `x/nft` stores are deleted.

---

## Cosmovisor (recommended)

Plan name **must** be `v6` — that is the handler Cosmovisor looks up.

```sh
# one-time env (systemd Environment= is better than ~/.profile)
export DAEMON_NAME=terpd
export DAEMON_HOME=$HOME/.terpd
export DAEMON_ALLOW_DOWNLOAD_BINARIES=false
export DAEMON_RESTART_AFTER_UPGRADE=true
export UNSAFE_SKIP_BACKUP=false   # set true only if you accept no pre-upgrade backup

mkdir -p "$DAEMON_HOME/cosmovisor/upgrades/v6/bin"

# After v6.0.0 is tagged and you have built/downloaded the binary:
#   make install   OR copy the release artifact
cp "$(command -v terpd)" "$DAEMON_HOME/cosmovisor/upgrades/v6/bin/terpd"
"$DAEMON_HOME/cosmovisor/upgrades/v6/bin/terpd" version
```

If you allow auto-download, point `plan.info` at `networks/upgrades/v6/cosmovisor.json` once checksums are filled.

No pre-upgrade `config.toml` rewrite is required for v6 (that was a v5 timeout_commit change).

---

## Manual upgrade

1. Watch height `22611000`. The node will panic/halt on the `v6` plan.
2. Then:

```sh
cd $HOME/terp-core
git fetch --tags
git checkout v6.0.0
make install
# restart terpd / cosmovisor
```

3. Confirm:

```sh
terpd q upgrade applied v6
terpd q wasm params
```

Circuit store/pin is **nobody** after the handler.

---

## Operator checklist

- [ ] Cosmovisor `upgrades/v6/bin/terpd` in place **before** halt
- [ ] Disk headroom for a state backup (`UNSAFE_SKIP_BACKUP=false`)
- [ ] No in-flight PFM packets with `nonrefundable=true` (ibc-go PFM v3→v4 aborts)
- [ ] Peers/seeds still reachable after restart
- [ ] After halt: `applied v6`, wasm + tokenfactory query

---

## Repo pack

| File | Role |
|---|---|
| `cosmovisor.json` | Binary URLs for `plan.info` (checksums after release) |
| `draft_proposal.json` | Gov `MsgSoftwareUpgrade` draft |
| `draft_metadata.json` | Off-chain proposal metadata |
| `chain-registry/versions.entry.json` | Entry to append to cosmos/chain-registry `terpnetwork/versions.json` |
| `chain-registry/chain.codebase.patch.json` | `codebase` block for `terpnetwork/chain.json` after upgrade |

Proposal ID stays `TBD` until on-chain. Height is the coordinated target, not yet locked by a vote.
