# Validator ping — patch to v6.0.1 (rolling, no halt height)

Copy from **@validator** down. This is **not** the v6.1 / v6.2 gov upgrade.

---

@validator hi!

First, my apologies for the bit of silence over the weekend. I will share more details in a bit about progress and the upgrade proposal posted last night.

**In the meantime, please patch your nodes ASAP** to the **v6.0 line** rolling binary below. This is **not** the v6.1 / v6.2 gov halt. It is a **binary swap on the live v6.0.0 stack** (SDK 0.54 / CometBFT 0.39) for CosmWasm nil-Ok halt plus related sudo isolation. There is **no upgrade height**. Swap every validator and sentry **together**.

- Tag: **`v6.0.1`** (`c8ba8176dae8b0cd624acb804ca9b6b1fea14af0`)
- Do **not** install `v6.1.0` / `v6.2.0` for this
- Cosmovisor: replace **`current`** (usually `genesis/bin/terpd`), **not** `upgrades/v6.1`

Confirm after start: `terpd version` → **6.0.1** / **c8ba8176dae8b0cd624acb804ca9b6b1fea14af0**

---

## Option A — download linux tarball (preferred)

### amd64

```bash
cd /tmp
curl -fL -O https://s3.terp.network/releases/terp-core/v6.0.1/terpd-6.0.1-linux-amd64.tar.gz
curl -fL -O https://s3.terp.network/releases/terp-core/v6.0.1/sha256sum.txt
echo "e4dd72f5a6cba3af602b49e51ee79229432f5de02dc23e586c5c6b7768dc285c  terpd-6.0.1-linux-amd64.tar.gz" | sha256sum -c
sudo systemctl stop terpd
tar -C "${DAEMON_HOME:-$HOME/.terpd}/cosmovisor/current/bin" -xzf terpd-6.0.1-linux-amd64.tar.gz
sudo systemctl start terpd
terpd version
```

### arm64

```bash
cd /tmp
curl -fL -O https://s3.terp.network/releases/terp-core/v6.0.1/terpd-6.0.1-linux-arm64.tar.gz
curl -fL -O https://s3.terp.network/releases/terp-core/v6.0.1/sha256sum.txt
echo "0b8d21b0bbe3cb593fb77c5cdd413d712aaf9465981180e2ca1f074f81c5cbc8  terpd-6.0.1-linux-arm64.tar.gz" | sha256sum -c
sudo systemctl stop terpd
tar -C "${DAEMON_HOME:-$HOME/.terpd}/cosmovisor/current/bin" -xzf terpd-6.0.1-linux-arm64.tar.gz
sudo systemctl start terpd
terpd version
```

### Auto-detect arch (linux amd64 or arm64)

```bash
case "$(uname -m)" in
  x86_64)        GOARCH=amd64 ;;
  aarch64|arm64) GOARCH=arm64 ;;
  *) echo "unsupported arch $(uname -m)"; exit 1 ;;
esac
cd /tmp
curl -fL -O "https://s3.terp.network/releases/terp-core/v6.0.1/terpd-6.0.1-linux-${GOARCH}.tar.gz"
curl -fL -O https://s3.terp.network/releases/terp-core/v6.0.1/sha256sum.txt
sha256sum -c sha256sum.txt --ignore-missing
sudo systemctl stop terpd
tar -C "${DAEMON_HOME:-$HOME/.terpd}/cosmovisor/current/bin" -xzf "terpd-6.0.1-linux-${GOARCH}.tar.gz"
sudo systemctl start terpd
terpd version
```

Tarball member is **`terpd`**.

| file | sha256 |
|---|---|
| `terpd-6.0.1-linux-amd64.tar.gz` | `e4dd72f5a6cba3af602b49e51ee79229432f5de02dc23e586c5c6b7768dc285c` |
| `terpd-6.0.1-linux-arm64.tar.gz` | `0b8d21b0bbe3cb593fb77c5cdd413d712aaf9465981180e2ca1f074f81c5cbc8` |

Checksums: https://s3.terp.network/releases/terp-core/v6.0.1/sha256sum.txt

---

## Option B — build from git (linux amd64 or arm64)

Run **inside** the terp-core clone, not from `$HOME`.

```bash
cd /path/to/terp-core
git fetch origin tag v6.0.1
git checkout v6.0.1
git submodule update --init crates/zk-wasmd crates/zk-wasmvm

case "$(uname -m)" in
  x86_64)        MUSLC=x86_64 ;;
  aarch64|arm64) MUSLC=aarch64 ;;
  *) echo "unsupported arch $(uname -m)"; exit 1 ;;
esac
mkdir -p crates/zk-wasmvm/internal/api
curl -fL --retry 3 -o "crates/zk-wasmvm/internal/api/libwasmvm_muslc.${MUSLC}.a" \
  "https://minio.terp.network/releases/zk-wasmvm/v3.0.7-zk/libwasmvm_muslc.${MUSLC}.a"

LEDGER_ENABLED=false BUILD_TAGS=muslc LINK_STATICALLY=true \
  make install RELEASE_TAG=v6.0.1 WASMVM_SOURCE=local

sudo systemctl stop terpd
install -m 755 "$(go env GOPATH)/bin/terpd" \
  "${DAEMON_HOME:-$HOME/.terpd}/cosmovisor/current/bin/terpd"
sudo systemctl start terpd
terpd version
```

If Cosmovisor `current` is not `genesis` yet, still replace `$DAEMON_HOME/cosmovisor/current/bin/terpd`.

Ping when you are on **6.0.1**. The v6.1 proposal (halt **23191300**) is a separate later step.
