# Mainnet Upgrade Guide: From Version v6 to v6.1 (then v6.2)

## Overview

This is a **coordinated** software upgrade on **morocco-1** (standard governance
voting period, not expedited). Validators **must** halt at the upgrade height and
restart with the `v6.1.0` binary. Cosmovisor does this automatically if the
upgrade binary is pre-placed.

Plan **`v6.2` is not a second proposal**. The v6.1 handler arms `v6.2` at
**apply + 2**. You will halt **twice**, about two blocks apart. Cosmovisor is
**required** for both swaps — do not run the upgrade as a hand-swapped
`terpd start`.

- **Chain**: `morocco-1`
- **Plan name** (must match `app/upgrades`): `v6.1` then `v6.2`
- **Git tags / binaries**: `v6.1.0` then `v6.2.0`
- **v6.1 proposal**: [Gov 59](https://www.ping.pub/terp/gov/59)
- **Upgrade height (v6.1)**: `23191300`
- **Countdown**: [Block countdown](https://www.ping.pub/terp/block/23191300)
- **v6.2 height**: v6.1 apply height **+ 2** (written by the v6.1 binary)
- **Release**: [v6.1.0](https://s3.terp.network/releases/terp-core/v6.1.0/) · [v6.2.0](https://s3.terp.network/releases/terp-core/v6.2.0/)
- **Cosmovisor JSON**: [v6.1](https://s3.terp.network/upgrades/v6.1/cosmovisor.json) · [v6.2](https://s3.terp.network/upgrades/v6.2/cosmovisor.json)

Plan directory names are **`v6.1` and `v6.2`**, not `v6.1.0`. Linux **amd64** and
**arm64** only — do not put a darwin `terpd` under Cosmovisor.

If `ExecStart` is already `cosmovisor run start`, skip to
[Pre-place both binaries](#pre-place-both-binaries-before-halt).
If it is raw `terpd start`, start at [Install Cosmovisor](#install-cosmovisor-first-time).

**Contract authors:** submessage **actions still happen**; `reply.events` no
longer includes bank/`instantiate` plumbing. Audit list:
[`CONTRACT-BREAKING.md`](./CONTRACT-BREAKING.md).

---

## Cosmovisor (required)

Cosmovisor swaps `terpd` at the on-chain plan name. Docs:
[Cosmovisor](https://docs.cosmos.network/main/tooling/cosmovisor).

### Install (first time)

Do this **once**, on each existing node (validator **and** sentries), **before**
height `23191300`. Same `--home` as today.

```sh
# confirm you are on raw terpd
systemctl cat terpd | grep ExecStart
# if you see `terpd start` (not `cosmovisor run start`), continue

# SDK 0.50+ module path (do not use github.com/cosmos/cosmos-sdk/cosmovisor@v1.0.0)
go install cosmossdk.io/tools/cosmovisor/cmd/cosmovisor@v1.7.1
command -v cosmovisor   # usually ~/go/bin/cosmovisor
```

If you do not build Go tools on the host, copy a linux `cosmovisor` binary for
your arch into `/usr/local/bin` instead.

```sh
export DAEMON_NAME=terpd
export DAEMON_HOME="${DAEMON_HOME:-$HOME/.terpd}"

mkdir -p "$DAEMON_HOME/cosmovisor/genesis/bin"
mkdir -p "$DAEMON_HOME/cosmovisor/upgrades"

# live v6 binary (whatever you run today)
install -m 0755 "$(command -v terpd)" "$DAEMON_HOME/cosmovisor/genesis/bin/terpd"
"$DAEMON_HOME/cosmovisor/genesis/bin/terpd" version
```

Persist environment in the systemd unit (or an `EnvironmentFile=`), then
**restart once** so Cosmovisor is the parent:

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
ps aux | grep -E 'cosmovisor|terpd'
curl -s localhost:26657/status | jq '.result.sync_info.latest_block_height, .result.sync_info.catching_up'
```

Run the node **through** Cosmovisor, not raw `terpd start`:

```sh
cosmovisor run start
```

### Pre-place both binaries (before halt)

Plan directory names **must** equal the on-chain upgrade names (`v6.1` and
`v6.2`, not the git tags). Place **both** before height `23191300`.

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

If a checksum fails, **stop** and ask in the validator channel before the height.

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
export DAEMON_NAME=terpd
export DAEMON_HOME="$HOME/.terpd"
export DAEMON_ALLOW_DOWNLOAD_BINARIES=false
export DAEMON_RESTART_AFTER_UPGRADE=true
export DAEMON_POLL_INTERVAL=300ms
export UNSAFE_SKIP_BACKUP=true
```

With both binaries on disk, leave download **off**. You do not need to restart
Cosmovisor after placing files if it is already `cosmovisor run start`.

At height `23191300` Cosmovisor restarts into `v6.1`. Two blocks later it
restarts into `v6.2`. If `upgrades/v6.2/bin/terpd` is missing, **your node stays
halted while the network moves on.**

---

## Do not hand-swap `terpd` at halt

There is no supported manual path for these two back-to-back plans. Install
Cosmovisor and pre-place both binaries **before** `23191300`.

---

## Binaries

| Platform | v6.1.0 | v6.2.0 |
|----------|--------|--------|
| linux/amd64 | [S3 tarball](https://s3.terp.network/releases/terp-core/v6.1.0/terpd-6.1.0-linux-amd64.tar.gz) `sha256:18a073f5d189f823987bd73d1ee6d410f9f48bbdcc92258fcbf8ae800780ebd2` | [S3 tarball](https://s3.terp.network/releases/terp-core/v6.2.0/terpd-6.2.0-linux-amd64.tar.gz) `sha256:38c15e1f54bc8234d07883c05e665ded68fdc0434c1c9db08de796d15ef491f6` |
| linux/arm64 | [S3 tarball](https://s3.terp.network/releases/terp-core/v6.1.0/terpd-6.1.0-linux-arm64.tar.gz) `sha256:4249119ebdbf75535c6852226fb7dee477373d65d2b721708bbb5265e8fdd8b4` | [S3 tarball](https://s3.terp.network/releases/terp-core/v6.2.0/terpd-6.2.0-linux-arm64.tar.gz) `sha256:148eedb6e8f1dd97e2436bc1b36dfebdbc915d23c14e6bad483924b0a4052c3d` |

---

## After halt

```sh
# after v6.1
terpd q upgrade applied v6.1 --home "$DAEMON_HOME" --node tcp://127.0.0.1:26657
readlink "$DAEMON_HOME/cosmovisor/current"    # …/upgrades/v6.1

# after v6.2 (~two blocks later)
terpd q upgrade applied v6.2 --home "$DAEMON_HOME" --node tcp://127.0.0.1:26657
readlink "$DAEMON_HOME/cosmovisor/current"    # …/upgrades/v6.2
"$DAEMON_HOME/cosmovisor/current/bin/terpd" version   # 6.2.0

terpd q wasm params     # circuit_upload_access should be Nobody
terpd status            # catching_up false, height moving
```

Repeat on **validator and every sentry**.

---

## Additional resources

- Operator note (same facts, more Cosmovisor download detail): [`PROVIDERS-v6.1-v6.2.md`](../PROVIDERS-v6.1-v6.2.md)
- v6.2 companion: [`../v6.2/guide.md`](../v6.2/guide.md)
- Docs: https://docs.terp.network
- Discord: https://discord.gg/pAxjcFnAFH
