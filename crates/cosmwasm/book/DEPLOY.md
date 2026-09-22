# Deploy The ZK-CosmWasm Book (groot2 / MinIO / Cloudflare)

Public URL: **https://zk.permissionless.money/**

## Object store

| Item | Value |
|------|--------|
| Bucket | `static` (same family as other static sites) |
| Prefix | `zk.permissionless.money/book/` |
| Local build | `mdbook build` → `book/book/` (HTML tree) |

## Upload (uses existing mc alias auth)

```bash
# From monorepo
cd websites
./scripts/deploy-mdbook.sh              # build + mirror
./scripts/deploy-mdbook.sh --dry-run    # preview
./scripts/deploy-mdbook.sh --no-build   # if already built

# Or with other sites (same MINIO_ALIAS as always)
./scripts/minio-upload.sh
# BUILD_BOOK=0 ./scripts/minio-upload.sh   # skip mdbook rebuild
```

Env (same as website deploys): `MINIO_ALIAS` (default `usb2`), optional `MINIO_USER`/`MINIO_KEY`/`MEDIA_CENTER_HOST` if creating alias.

## Nginx (origin on groot2)

```bash
# Option A — dedicated conf
sudo cp websites/permissionless.money/nginx/zk.permissionless.money.conf \
  /etc/nginx/sites-available/
sudo ln -sf /etc/nginx/sites-available/zk.permissionless.money.conf \
  /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

# Option B — already embedded in crates/o-line/config/edge/terp-static.nginx.conf
# Install that snapshot as the static sites conf, then reload.
```

## Cloudflare tunnel (cloudflared only — no oline required)

Groot2 typically already has tunnel **`websites`** + zone certs under `~/.cloudflared/`.  
You only need **(1) DNS CNAME → tunnel** and **(2) ingress hostname → local nginx**.

### 1) DNS: point hostname at the tunnel

```bash
# List tunnels if you forget the name/UUID
cloudflared tunnel list

# Zone origin cert for permissionless.money (path on groot2 — adjust if different)
export TUNNEL_ORIGIN_CERT="${TUNNEL_ORIGIN_CERT:-$HOME/.cloudflared/cert-pm.pem}"

# Bind zk.permissionless.money → tunnel (force overwrite if stale)
# Use tunnel NAME or UUID from `cloudflared tunnel list`
cloudflared tunnel route dns -f websites zk.permissionless.money
# if your tunnel is not named websites:
# cloudflared tunnel route dns -f <TUNNEL_UUID_OR_NAME> zk.permissionless.money
```

### 2) Ingress: serve that hostname from local nginx (:80)

Edit `~/.cloudflared/config.yml` (or wherever the tunnel service loads).  
**Add a rule above the catch-all** `http_status:404`:

```yaml
ingress:
  # … existing hostnames (permissionless.money, terp.network, …) …
  - hostname: zk.permissionless.money
    service: http://127.0.0.1:80
  - service: http_status:404
```

Restart the tunnel so it picks up ingress:

```bash
# systemd unit name varies — common patterns:
sudo systemctl restart cloudflared
# or:
sudo systemctl restart cloudflared.service
# or user service:
systemctl --user restart cloudflared
```

### 3) Smoke

```bash
curl -sI https://zk.permissionless.money/ | head -15
curl -sL https://zk.permissionless.money/ | head -5
curl -sL -o /dev/null -w '%{http_code}\n' \
  https://zk.permissionless.money/using/vm/proof-vm.html
```

**Note:** `oline edge tunnel-route` only wraps the same `cloudflared tunnel route dns` call; skip oline if it is not installed on groot2.

## Smoke

```bash
curl -sI https://zk.permissionless.money/ | head -10
curl -sL https://zk.permissionless.money/using/vm/proof-vm.html | head -5
curl -sL -o /dev/null -w '%{http_code}\n' https://zk.permissionless.money/using/tooling/cw-orch.html
```

## Desk link (optional)

Point grant desk “docs / book” to `https://zk.permissionless.money/` when live.
