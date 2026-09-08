ARG GO_VERSION=1.25
ARG RUNNER_IMAGE=alpine:3.17

# WASMVM_SOURCE controls where the static wasmvm library comes from:
#   "github" (default) — download libwasmvm_muslc from minio.terp.network/releases/zk-wasmvm/<ver>/
#   "local"            — use pre-built lib from build/wasmvm/ (for custom zk-wasmvm)
ARG WASMVM_SOURCE=github
ARG WASMVM_BASE_URL=https://minio.terp.network/releases/zk-wasmvm

FROM golang:${GO_VERSION}-alpine AS go-builder
# Stamped into terpd via make VERSION=/COMMIT= (.git is dockerignored).
ARG GIT_VERSION=
ARG GIT_COMMIT=

SHELL ["/bin/sh", "-ecuxo", "pipefail"]
# this comes from standard alpine nightly file
#  https://github.com/rust-lang/docker-rust-nightly/blob/master/alpine3.12/Dockerfile
# with some changes to support our toolchain, etc
RUN apk add --no-cache ca-certificates build-base git binutils-gold musl-dev gcc libc-dev
# NOTE: add these to run with LEDGER_ENABLED=true
# RUN apk add libusb-dev linux-headers

WORKDIR /code

# Pull in the go.mod file *first* so the layer can be cached
ADD go.mod go.sum ./

# Re-declare ARGs after FROM (Docker scoping rule)
ARG WASMVM_SOURCE
ARG WASMVM_BASE_URL

# ---------------------------------------------------------
# Pull in the wasmvm static library (github mode only).
# In local mode the lib is staged in build/wasmvm/ and will
# be copied after the full source COPY below.
#
# Do NOT use `go list -m` here: go.mod may replace wasmvm → ./crates/zk-wasmvm
# and crates/ is dockerignored until staging; parse the require line instead.
# ---------------------------------------------------------
RUN if [ "$WASMVM_SOURCE" = "github" ]; then \
      WASMVM_VERSION=$(awk '/^[[:space:]]*github.com\/CosmWasm\/wasmvm\/v3/ && !/=>/ {print $2; exit}' go.mod) && \
      if [ -z "$WASMVM_VERSION" ]; then echo "ERROR: could not parse wasmvm version from go.mod"; exit 1; fi && \
      ARCH=$(uname -m) && \
      BASE="${WASMVM_BASE_URL:-https://minio.terp.network/releases/zk-wasmvm}" && \
      echo "==> Downloading wasmvm $WASMVM_VERSION from $BASE ($ARCH)" && \
      wget -q "$BASE/$WASMVM_VERSION/libwasmvm_muslc.$ARCH.a" \
           -O /lib/libwasmvm_muslc.$ARCH.a && \
      wget -q "$BASE/$WASMVM_VERSION/SHA256SUMS" -O /tmp/SHA256SUMS && \
      sha256sum /lib/libwasmvm_muslc.$ARCH.a | grep $(grep libwasmvm_muslc.$ARCH /tmp/SHA256SUMS | awk '{print $1}'); \
    else \
      echo "==> Skipping GitHub download (WASMVM_SOURCE=$WASMVM_SOURCE)"; \
    fi

# ---------------------------------------------------------
# Copy the source tree (everything) and build *statically*
# (.dockerignore excludes crates/ — ZK sources must be under build/zk-deps/)
# ---------------------------------------------------------
COPY . /code/

# ---------------------------------------------------------
# Prepare go.mod & wasmvm lib based on source mode
# ---------------------------------------------------------
RUN ARCH=$(uname -m) && \
    if [ "$WASMVM_SOURCE" = "local" ]; then \
      echo "==> Using local zk-wasmvm / zk-wasmd (go replace + staged muslc)" && \
      # --- static lib (also living under build/zk-deps/.../internal/api via rsync) --- \
      if [ ! -f /code/build/wasmvm/libwasmvm_muslc.$ARCH.a ]; then \
        echo "ERROR: build/wasmvm/libwasmvm_muslc.$ARCH.a not found." && \
        echo "Run 'make docker-stage-zk' / build-zk-local first to stage zk dependencies." && \
        exit 1; \
      fi && \
      cp /code/build/wasmvm/libwasmvm_muslc.$ARCH.a /lib/libwasmvm_muslc.$ARCH.a && \
      # Keep go replace to monorepo ZK forks — rewrite host paths → staged docker paths.
      # crates/ is dockerignored; build/zk-deps is what the image actually contains.
      if [ ! -f /code/build/zk-deps/zk-wasmvm/go.mod ] || [ ! -f /code/build/zk-deps/zk-wasmd/go.mod ]; then \
        echo "ERROR: staged zk-deps missing. Need build/zk-deps/zk-wasmvm and zk-wasmd." && \
        exit 1; \
      fi && \
      if [ ! -f /code/build/zk-deps/ibc-hooks-v11/go.mod ]; then \
        echo "ERROR: staged ibc-hooks-v11 missing under build/zk-deps." && \
        exit 1; \
      fi && \
      # Ensure muslc .a is present where cgo LDFLAGS ${SRCDIR} looks (internal/api)
      cp /code/build/wasmvm/libwasmvm_muslc.$ARCH.a \
         /code/build/zk-deps/zk-wasmvm/internal/api/libwasmvm_muslc.$ARCH.a && \
      sed -i 's|=> \./crates/zk-wasmvm|=> /code/build/zk-deps/zk-wasmvm|g' /code/go.mod && \
      sed -i 's|=> \./crates/zk-wasmd|=> /code/build/zk-deps/zk-wasmd|g'   /code/go.mod && \
      sed -i 's|=> \./crates/ibc-hooks-v11|=> /code/build/zk-deps/ibc-hooks-v11|g' /code/go.mod && \
      # Also accept already-rewritten or alternate relative forms
      sed -i 's|=> \.\./zk-wasmvm|=> /code/build/zk-deps/zk-wasmvm|g' /code/go.mod && \
      sed -i 's|=> \.\./zk-wasmd|=> /code/build/zk-deps/zk-wasmd|g'   /code/go.mod && \
      echo "==> go.mod replaces after rewrite:" && \
      grep -E 'CosmWasm/(wasmd|wasmvm)' /code/go.mod | head -20; \
    else \
      echo "==> Stripping local ZK replace directives for stock (github wasmvm) build" && \
      # Remove monorepo path replaces so require lines resolve to module proxy
      sed -i '/github.com\/CosmWasm\/wasmd => \.\/crates\/zk-wasmd/d' /code/go.mod && \
      sed -i '/github.com\/CosmWasm\/wasmvm\/v3 => \.\/crates\/zk-wasmvm/d' /code/go.mod && \
      sed -i '/github.com\/CosmWasm\/wasmd => \/code\/build\/zk-deps\/zk-wasmd/d' /code/go.mod && \
      sed -i '/github.com\/CosmWasm\/wasmvm\/v3 => \/code\/build\/zk-deps\/zk-wasmvm/d' /code/go.mod && \
      sed -i '/=> \.\.\/zk-wasmvm/d' /code/go.mod && \
      sed -i '/=> \.\.\/zk-wasmd/d'  /code/go.mod && \
      sed -i '/zk-circuit flavored wasmd/d' /code/go.mod && \
      sed -i '/zk-circuit flavored wasmvm/d' /code/go.mod; \
    fi

# force it to use static lib (from above) not standard libgo_cosmwasm.so file
RUN go mod tidy && LEDGER_ENABLED=false BUILD_TAGS=muslc LINK_STATICALLY=true make build VERSION="${GIT_VERSION}" COMMIT="${GIT_COMMIT}"
RUN echo "Ensuring binary is statically linked ..." \
  && (file /code/build/terpd | grep "statically linked")

# ---------------------------------------------------------
# 1. Runtime image — standard (github wasmvm)
# ---------------------------------------------------------
FROM ${RUNNER_IMAGE} AS runtime

# Copy ca-certificates from builder (works on distroless, Alpine, and nonroot)
COPY --from=go-builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt

COPY --from=go-builder /code/build/terpd /usr/local/bin/terpd

ENV HOME=/terpd
WORKDIR $HOME

# expose the usual Tendermint ports
EXPOSE 1317 26656 26657

CMD ["/usr/local/bin/terpd"]

# ---------------------------------------------------------
# 2. Localterp bootstrap image
# ---------------------------------------------------------
FROM alpine:3.17 AS localterp
RUN apk add --no-cache \
        ca-certificates \
        bash \
        jq \
        perl \
        curl \
        nodejs \
        npm

RUN rm -rf /var/lib/apt/lists/* && npm i -g local-cors-proxy

COPY --from=go-builder /code/build/terpd /usr/local/bin/terpd

WORKDIR /code
COPY docker/localterp/bootstrap.sh .
COPY docker/localterp/initialize.sh .
COPY docker/localterp/start.sh .
COPY docker/localterp/faucet/faucet_server.js .

RUN chmod +x *.sh

# 1317=LCD proxy, 5000=faucet, 26656=P2P, 26657=RPC, 9090=GRPC
EXPOSE 1317 5000 26656 26657 9090

HEALTHCHECK --interval=5s --timeout=1s --retries=120 \
  CMD bash -c 'curl -sfm1 http://localhost:26657/status && \
               curl -s http://localhost:26657/status | jq -e "(.result.sync_info.latest_block_height | tonumber) > 0"'

ENTRYPOINT ["/code/bootstrap.sh"]
