# Mainnet Upgrade Guide: Plan v6.2 (armed by v6.1)

## Overview

Plan **`v6.2` is not a second governance proposal**. The v6.1 handler writes this
plan at **apply + 2**. You must already be on Cosmovisor with **both** binaries
pre-placed **before** the v6.1 height. Full operator path:
[`../v6.1/guide.md`](../v6.1/guide.md).

- **Chain**: `morocco-1`
- **Plan name** (must match `app/upgrades`): `v6.2`
- **Git tag / binary**: `v6.2.0`
- **Height**: v6.1 apply height **+ 2** (not submitted as its own proposal)
- **Release**: [S3 v6.2.0](https://s3.terp.network/releases/terp-core/v6.2.0/)
- **Cosmovisor JSON** (what v6.1 writes into `plan.info`):
  [upgrades/v6.2/cosmovisor.json](https://s3.terp.network/upgrades/v6.2/cosmovisor.json)

If Cosmovisor does not have `upgrades/v6.2/bin/terpd` (and cannot download it),
**your node stays halted on `UPGRADE "v6.2" NEEDED` while the network moves on.**

---

## Cosmovisor (required)

Cosmovisor swaps `terpd` at the on-chain plan name (`v6.2`). Docs:
[Cosmovisor](https://docs.cosmos.network/main/tooling/cosmovisor).

If you are not yet running `cosmovisor run start`, follow
[Install Cosmovisor](../v6.1/guide.md#install-cosmovisor-first-time) first, then
return here.

### Pre-place the v6.2 binary (before the v6.1 halt)

Plan directory name **must** equal `v6.2`, not the git tag. Do this on every
validator and sentry **before** height `23191300`.

**linux/amd64**

```sh
curl -fsSL -o terpd-6.2.0-linux-amd64.tar.gz \
  "https://s3.terp.network/releases/terp-core/v6.2.0/terpd-6.2.0-linux-amd64.tar.gz"
echo "38c15e1f54bc8234d07883c05e665ded68fdc0434c1c9db08de796d15ef491f6  terpd-6.2.0-linux-amd64.tar.gz" | sha256sum -c
```

**linux/arm64**

```sh
curl -fsSL -o terpd-6.2.0-linux-arm64.tar.gz \
  "https://s3.terp.network/releases/terp-core/v6.2.0/terpd-6.2.0-linux-arm64.tar.gz"
echo "148eedb6e8f1dd97e2436bc1b36dfebdbc915d23c14e6bad483924b0a4052c3d  terpd-6.2.0-linux-arm64.tar.gz" | sha256sum -c
```

```sh
export DAEMON_HOME="${DAEMON_HOME:-$HOME/.terpd}"
mkdir -p "$DAEMON_HOME/cosmovisor/upgrades/v6.2/bin"
# amd64 example — use the arm64 tarball on arm64 hosts
tar -xzf terpd-6.2.0-linux-amd64.tar.gz -C "$DAEMON_HOME/cosmovisor/upgrades/v6.2/bin"
chmod +x "$DAEMON_HOME/cosmovisor/upgrades/v6.2/bin/terpd"
"$DAEMON_HOME/cosmovisor/upgrades/v6.2/bin/terpd" version   # 6.2.0
```

Keep `DAEMON_ALLOW_DOWNLOAD_BINARIES=false` when both binaries are on disk.
Do **not** create an empty `upgrades/v6.2/` directory if you intend Cosmovisor
to download — it will not fetch over an existing dir.

---

## Do not hand-swap `terpd` at halt

There is no supported manual path for the v6.1 → v6.2 pair. Pre-place this
binary before the v6.1 height.

---

## Binaries

| Platform | Artifact |
|----------|----------|
| linux/amd64 | [S3 tarball](https://s3.terp.network/releases/terp-core/v6.2.0/terpd-6.2.0-linux-amd64.tar.gz) `sha256:38c15e1f54bc8234d07883c05e665ded68fdc0434c1c9db08de796d15ef491f6` |
| linux/arm64 | [S3 tarball](https://s3.terp.network/releases/terp-core/v6.2.0/terpd-6.2.0-linux-arm64.tar.gz) `sha256:148eedb6e8f1dd97e2436bc1b36dfebdbc915d23c14e6bad483924b0a4052c3d` |

---

## After halt

```sh
terpd q upgrade applied v6.2 --home "$DAEMON_HOME" --node tcp://127.0.0.1:26657
readlink "$DAEMON_HOME/cosmovisor/current"    # …/upgrades/v6.2
"$DAEMON_HOME/cosmovisor/current/bin/terpd" version   # 6.2.0
terpd status
```

---

## Additional resources

- v6.1 + Cosmovisor install: [`../v6.1/guide.md`](../v6.1/guide.md)
- Operator note: [`../PROVIDERS-v6.1-v6.2.md`](../PROVIDERS-v6.1-v6.2.md)
- Docs: https://docs.terp.network
- Discord: https://discord.gg/pAxjcFnAFH
