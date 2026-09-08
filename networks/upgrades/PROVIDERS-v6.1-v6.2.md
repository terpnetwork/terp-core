# Morocco-1 software upgrade: v6.1 then v6.2

**Status:** Expedited plan **`v6.1` at height `23097500`**. Voting period is **24 hours**. Halt is ~**12 hours after** voting ends (~**36 hours** from 2026-09-08 06:07 UTC at ~**3.5 s/block**). Between now and height `23097500`, every validator and sentry must run **`cosmovisor run start`**, not raw `terpd start`. Plan **`v6.2` is not a second proposal** — the v6.1 binary arms it at apply + 2.

The chain will halt **twice**, about **two blocks** apart. Cosmovisor is how you make both swaps without sitting on the keyboard. This note does **not** describe a manual binary swap for the upgrade itself.

If you already run Cosmovisor, skip to [If you already run Cosmovisor](#if-you-already-run-cosmovisor).  
If `ExecStart` is `terpd start`, start at [If you do not run Cosmovisor yet](#if-you-do-not-run-cosmovisor-yet).

You can follow this yourself, or paste [Facts for an assistant](#facts-for-an-assistant-copy-from-here) into an LLM and point it at your hosts.

---

## What happens on chain

Two named upgrades, in order. You cannot skip the first.

| Order | Plan name (folder / log line) | Binary | What it does |
|-------|-------------------------------|--------|----------------|
| 1 | `v6.1` | `terpd` **6.1.0** | Upgrade A. At apply height it **schedules plan `v6.2` at height + 2**. |
| 2 | `v6.2` | `terpd` **6.2.0** | Upgrade B. IBC stays SHA-256. |

Plan names are **`v6.1` and `v6.2`**, not `v6.1.0`. Cosmovisor directories must match those names exactly.

Governance submits **only** plan `v6.1`. `x/upgrade` keeps one plan (last message wins). The v6.1 binary writes the v6.2 plan, including:

```text
https://s3.terp.network/upgrades/v6.2/cosmovisor.json
```

That object is linux download URLs plus sha256. It is not ELF hashes baked into 6.1.0.

On upgrade day you should see:

1. `UPGRADE "v6.1" NEEDED` at the proposal height → Cosmovisor starts 6.1.0.
2. Two blocks later, `UPGRADE "v6.2" NEEDED` (expected) → Cosmovisor starts 6.2.0.
3. The node keeps producing blocks.

If Cosmovisor does not have a 6.2.0 binary (and cannot download one), **your node stays halted while the network moves on.**

Linux **amd64** and **arm64** only. Do not put a darwin `terpd` under Cosmovisor.

Index: [resources v6.1.0](https://terp.network/resources#releases/v6.1.0) · [v6.2.0](https://terp.network/resources#releases/v6.2.0)

---

## If you do not run Cosmovisor yet

Do this **once**, on each existing node, **before** the v6.1 height. Same `--home` as today. Then continue with [If you already run Cosmovisor](#if-you-already-run-cosmovisor).

### 1. Confirm you are on raw `terpd`

```sh
systemctl cat terpd | grep ExecStart
# if you see `terpd start` (not `cosmovisor run start`), continue
```

### 2. Install Cosmovisor v1.7.1

```sh
# SDK 0.50+ path — do not use github.com/cosmos/cosmos-sdk/cosmovisor@v1.0.0
go install cosmossdk.io/tools/cosmovisor/cmd/cosmovisor@v1.7.1
command -v cosmovisor   # usually ~/go/bin/cosmovisor
```

If you do not build Go tools on the host, copy a linux `cosmovisor` binary for your arch into `/usr/local/bin` instead.

### 3. Point Cosmovisor at the binary that is already running

`$DAEMON_HOME` is the same directory you pass to `terpd --home` (often `~/.terpd`).

```sh
export DAEMON_NAME=terpd
export DAEMON_HOME="${DAEMON_HOME:-$HOME/.terpd}"

mkdir -p "$DAEMON_HOME/cosmovisor/genesis/bin"
# copy the live v6 binary (whatever you run today)
install -m 0755 "$(command -v terpd)" "$DAEMON_HOME/cosmovisor/genesis/bin/terpd"
"$DAEMON_HOME/cosmovisor/genesis/bin/terpd" version
```

### 4. Persist environment and switch the unit to Cosmovisor

Put these in the systemd unit (or a file the unit `EnvironmentFile=`s), then **restart once** so Cosmovisor is the parent process:

```sh
DAEMON_NAME=terpd
DAEMON_HOME=/home/YOURUSER/.terpd
DAEMON_RESTART_AFTER_UPGRADE=true
DAEMON_POLL_INTERVAL=300ms
UNSAFE_SKIP_BACKUP=true
DAEMON_ALLOW_DOWNLOAD_BINARIES=false
```

```ini
[Service]
Environment=DAEMON_NAME=terpd
Environment=DAEMON_HOME=/home/YOURUSER/.terpd
Environment=DAEMON_RESTART_AFTER_UPGRADE=true
Environment=DAEMON_POLL_INTERVAL=300ms
Environment=UNSAFE_SKIP_BACKUP=true
Environment=DAEMON_ALLOW_DOWNLOAD_BINARIES=false
ExecStart=/usr/local/bin/cosmovisor run start --home /home/YOURUSER/.terpd
# keep the same extra flags you already use (p2p, pruning, gas, etc.)
```

```sh
sudo systemctl daemon-reload
sudo systemctl restart terpd
# confirm Cosmovisor is parent, node is still the same chain/height
ps aux | grep -E 'cosmovisor|terpd'
curl -s localhost:26657/status | jq '.result.sync_info.latest_block_height, .result.sync_info.catching_up'
```

Do this on **validator and sentries**. After this restart you are a Cosmovisor operator; the upgrade itself is the next section.

---

## If you already run Cosmovisor

Place both upgrade binaries **before** the v6.1 height, on every node. This is the path we recommend.

### Download and verify (your architecture)

Each tarball contains a single member named `terpd`.

**linux/amd64**

```sh
curl -fsSL -o terpd-6.1.0-linux-amd64.tar.gz \
  "https://s3.terp.network/releases/terp-core/v6.1.0/terpd-6.1.0-linux-amd64.tar.gz"
curl -fsSL -o terpd-6.2.0-linux-amd64.tar.gz \
  "https://s3.terp.network/releases/terp-core/v6.2.0/terpd-6.2.0-linux-amd64.tar.gz"

echo "18a073f5d189f823987bd73d1ee6d410f9f48bbdcc92258fcbf8ae800780ebd2  terpd-6.1.0-linux-amd64.tar.gz" | sha256sum -c
echo "38c15e1f54bc8234d07883c05e665ded68fdc0434c1c9db08de796d15ef491f6  terpd-6.2.0-linux-amd64.tar.gz" | sha256sum -c
```

**linux/arm64**

```sh
curl -fsSL -o terpd-6.1.0-linux-arm64.tar.gz \
  "https://s3.terp.network/releases/terp-core/v6.1.0/terpd-6.1.0-linux-arm64.tar.gz"
curl -fsSL -o terpd-6.2.0-linux-arm64.tar.gz \
  "https://s3.terp.network/releases/terp-core/v6.2.0/terpd-6.2.0-linux-arm64.tar.gz"

echo "4249119ebdbf75535c6852226fb7dee477373d65d2b721708bbb5265e8fdd8b4  terpd-6.1.0-linux-arm64.tar.gz" | sha256sum -c
echo "148eedb6e8f1dd97e2436bc1b36dfebdbc915d23c14e6bad483924b0a4052c3d  terpd-6.2.0-linux-arm64.tar.gz" | sha256sum -c
```

On macOS use `shasum -a 256 -c` if `sha256sum` is missing. If a checksum fails, **stop** and ask in the validator channel before the height.

Same hashes: https://s3.terp.network/upgrades/v6.1/cosmovisor.json · https://s3.terp.network/upgrades/v6.2/cosmovisor.json

Tags: **v6.1.0** = `612ebf3b6a3a2b524033091fd6db6223760837c0`, **v6.2.0** = `0c24074ea7a97c04119d890b224a56563325135d`.

### Pre-place both plan binaries

```sh
export DAEMON_HOME="${DAEMON_HOME:-$HOME/.terpd}"
export DAEMON_NAME=terpd

mkdir -p "$DAEMON_HOME/cosmovisor/upgrades/v6.1/bin" \
         "$DAEMON_HOME/cosmovisor/upgrades/v6.2/bin"

# amd64 example — use the arm64 tarballs on arm64 hosts
tar -xzf terpd-6.1.0-linux-amd64.tar.gz -C "$DAEMON_HOME/cosmovisor/upgrades/v6.1/bin"
tar -xzf terpd-6.2.0-linux-amd64.tar.gz -C "$DAEMON_HOME/cosmovisor/upgrades/v6.2/bin"
chmod +x "$DAEMON_HOME/cosmovisor/upgrades/v6.1/bin/terpd" \
         "$DAEMON_HOME/cosmovisor/upgrades/v6.2/bin/terpd"

"$DAEMON_HOME/cosmovisor/upgrades/v6.1/bin/terpd" version   # 6.1.0
"$DAEMON_HOME/cosmovisor/upgrades/v6.2/bin/terpd" version   # 6.2.0
```

Keep:

```sh
DAEMON_NAME=terpd
DAEMON_HOME=$HOME/.terpd
DAEMON_RESTART_AFTER_UPGRADE=true
UNSAFE_SKIP_BACKUP=true
DAEMON_ALLOW_DOWNLOAD_BINARIES=false
```

With both binaries on disk, leave download **off**. You do not need to restart Cosmovisor after placing files if it is already `cosmovisor run start`.

### Optional: Cosmovisor download instead of pre-placing v6.2

Only if you understand the pointer URL. Safer is still pre-place.

- Pre-place **v6.1**, or ensure gov `plan.info` for `v6.1` is the compact JSON from https://s3.terp.network/upgrades/v6.1/cosmovisor.json.
- Do **not** create an empty `upgrades/v6.2/` directory (Cosmovisor will not download over an existing dir).
- `DAEMON_ALLOW_DOWNLOAD_BINARIES=true`
- `DAEMON_DOWNLOAD_MUST_HAVE_CHECKSUM=false` (the v6.2 **JSON** URL has no `?checksum=`; tarball URLs inside it do).
- At v6.1 apply, 6.1.0 writes `plan.info` = `https://s3.terp.network/upgrades/v6.2/cosmovisor.json`. Cosmovisor GETs that and fetches the matching linux tarball.

Keep the 6.2.0 tarball on disk anyway if download fails.

### Upgrade-day checks

```sh
# after v6.1
terpd q upgrade applied v6.1 --home "$DAEMON_HOME" --node tcp://127.0.0.1:26657
readlink "$DAEMON_HOME/cosmovisor/current"    # …/upgrades/v6.1

# after v6.2 (~two blocks later)
terpd q upgrade applied v6.2 --home "$DAEMON_HOME" --node tcp://127.0.0.1:26657
readlink "$DAEMON_HOME/cosmovisor/current"    # …/upgrades/v6.2
"$DAEMON_HOME/cosmovisor/current/bin/terpd" version   # 6.2.0
```

Repeat on **validator and every sentry**.

---

## After both upgrades

```sh
terpd q upgrade applied v6.1
terpd q upgrade applied v6.2
terpd q wasm params     # circuit_upload_access should be Nobody
terpd status            # catching_up false, height moving
```

---

## Do not

- Do not run the upgrade as a hand-swapped `terpd start`. Install Cosmovisor first.
- Do not skip v6.1 or start 6.2.0 on v6 state.
- Do not put two `MsgSoftwareUpgrade` in one proposal (last plan wins). Submit **only `v6.1`**.
- Do not use plan names `v6` or `v6.1.0`, or darwin binaries.
- Do not set `DAEMON_DOWNLOAD_MUST_HAVE_CHECKSUM=true` if you rely on the v6.2 JSON URL.
- Do not wait until halt to download tarballs.
- Questions in the validator channel **before** the halt height.

---

## Facts for an assistant (copy from here)

```
Chain: morocco-1. Coordinated upgrade: plan v6.1 then plan v6.2 (~2 blocks later). Cosmovisor is required.
If ExecStart is terpd start: install cosmossdk.io/tools/cosmovisor/cmd/cosmovisor@v1.7.1, copy current terpd to $DAEMON_HOME/cosmovisor/genesis/bin/terpd, switch systemd to `cosmovisor run start` with same --home, restart once, confirm height still moving. Then treat as Cosmovisor operator.
Do not document a manual terpd stop/start for the two upgrade halts.
Governance: submit only plan v6.1. v6.1 binary schedules v6.2 at apply+2 with plan.info https://s3.terp.network/upgrades/v6.2/cosmovisor.json
v6.1.0 commit 612ebf3b6a3a2b524033091fd6db6223760837c0
v6.2.0 commit 0c24074ea7a97c04119d890b224a56563325135d
Tarballs (member terpd, linux only):
  v6.1 amd64 18a073f5d189f823987bd73d1ee6d410f9f48bbdcc92258fcbf8ae800780ebd2
    https://s3.terp.network/releases/terp-core/v6.1.0/terpd-6.1.0-linux-amd64.tar.gz
  v6.1 arm64 4249119ebdbf75535c6852226fb7dee477373d65d2b721708bbb5265e8fdd8b4
    https://s3.terp.network/releases/terp-core/v6.1.0/terpd-6.1.0-linux-arm64.tar.gz
  v6.2 amd64 38c15e1f54bc8234d07883c05e665ded68fdc0434c1c9db08de796d15ef491f6
    https://s3.terp.network/releases/terp-core/v6.2.0/terpd-6.2.0-linux-amd64.tar.gz
  v6.2 arm64 148eedb6e8f1dd97e2436bc1b36dfebdbc915d23c14e6bad483924b0a4052c3d
    https://s3.terp.network/releases/terp-core/v6.2.0/terpd-6.2.0-linux-arm64.tar.gz
Recommended: pre-place upgrades/v6.1/bin/terpd and upgrades/v6.2/bin/terpd, DAEMON_ALLOW_DOWNLOAD_BINARIES=false.
Optional download: ALLOW_DOWNLOAD true, MUST_HAVE_CHECKSUM false, do not create empty upgrades/v6.2/.
DAEMON_NAME=terpd DAEMON_RESTART_AFTER_UPGRADE=true. No darwin. Plan v6.1 halt height 23097500. v6.2 is apply+2 from the v6.1 binary.
```
