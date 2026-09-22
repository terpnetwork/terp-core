# Handoff: prune `registry.terp.network` (not GHCR)

We do **not** use GHCR. Operator images are `registry.terp.network/terp-core:<tag>`.
Libwasmvm **builder** images (`terpnetwork/zk-{alpine,debian,cross}-builder:4.0.0-zk`,
5.3GB / 2.3GB / 8.4GB) are **compile-time local only** — they are never pushed.
Compiled artifacts (linux muslc `terpd`, Cosmovisor tarballs, the ~300MB runtime
image) are what CI should emit on the `v6.3.0` / `v6.4.0` tags.

A docker push of `zk-alpine-builder:4.0.0-zk` (5.29GB) to
`registry.terp.network` returned **413 Payload Too Large** on a blob PUT
(Cloudflare + nginx in front of the registry). That is a **request body limit**,
not “the disk is full.” Pruning old tags will not raise `client_max_body_size`
and will not make 5GB toolchain layers succeed. Do **not** bump the proxy to
8GB so we can store rustc nightly. Prune anyway: the catalog is cluttered,
there is a ghost `zk-alpine-builder` repo from the aborted upload
(`/_catalog` listed it; tags/list and manifests 404), and we need a clean
namespace for `terp-core:v6.3.0` and `terp-core:v6.4.0` (~300MB, same class as
`v6.0.1` / `v6.3.0-dev` which already live there). After prune, a release
build pushes **only** `registry.terp.network/terp-core:v6.3.0` and `:v6.4.0`
(v6.4 is `-tags v64`). Do not add a second workflow that re-checks submodule
pins. Muslc `.a` stays on S3
`releases/zk-wasmvm/v4.0.0-zk/`, not in the container registry.

## Catalog (2026-09-22)

`GET https://registry.terp.network/v2/_catalog`:

`cosmos-omnibus`, `hash-market`, `headscale`, `hs-edge`, `lab/buzz-lab`,
`lab/localterp`, `minio-ipfs`, `sda-dev`, `terp-core`, `zakura`, `zebrad`,
`zk-alpine-builder` (ghost).

`terp-core` tags today:

`v6.0.0`, `v6.0.1`, `v6.0.1-curl`, `v6.0.1-linux-amd64`,
`v6.0.1-linux-amd64-curl`, `v6-linux-amd64`, `v6-linux-amd64-curl`,
`v6-sentry`, `v6.2.0-linux-amd64-curl`, `v5.2.0`, `v5.2.0-8-g5b432b6`,
`v5.1.6-oline`, `v6.1.0-dev-10ea0bc`, `local-zk`, `localterp`, `mainnet`,
`120u-1`, `120u-1-node`, `120u1-v5208-wasmvm`.

## Keep vs delete (confirm live morocco-1 pin first)

**Keep** (until you know a node still pulls them): `v6.0.0`, `v6.0.1` (and
one linux-amd64 alias if that is what sentries use), `v6.2.0-linux-amd64-curl`
if that is the current mainnet image, `v5.2.0` if e2e still upgrades from it.

**Delete** (safe clutter): `local-zk`, `localterp`, `mainnet` (unversioned),
`v5.2.0-8-g5b432b6` (git-describe), `v6.1.0-dev-*`, extra `-curl` duplicates
once one alias is chosen, `120u-1*`, ghost `zk-alpine-builder`. Do not create
`zk-debian-builder` / `zk-cross-builder`. Leave `headscale` / `zakura` /
`minio-ipfs` unless you know they are dead.

Harbor/distribution GC after tag delete, or the blobs stay. If the proxy must
change at all: keep the body limit sized for **~300MB terpd layers**, not
multi-GB builders.
