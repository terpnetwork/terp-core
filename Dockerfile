ARG GO_VERSION=1.24
ARG RUNNER_IMAGE=alpine:3.17
ARG COSMWASM_VERSION
# WASMVM_SOURCE controls where the static wasmvm library comes from:
#   "github" (default) — download libwasmvm_muslc from CosmWasm GitHub releases
#   "local"            — use pre-built lib from build/wasmvm/ (for custom zk-wasmvm)
ARG WASMVM_SOURCE=github

FROM golang:${GO_VERSION}-alpine AS go-builder

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
ARG COSMWASM_VERSION

# ---------------------------------------------------------
# Pull in the wasmvm static library (github mode only).
# In local mode the lib is staged in build/wasmvm/ and will
# be copied after the full source COPY below.
# ---------------------------------------------------------
RUN if [ "$WASMVM_SOURCE" = "github" ]; then \
      ARCH=$(uname -m) && \
      echo "==> Downloading wasmvm $COSMWASM_VERSION from GitHub ($ARCH)" && \
      wget -q https://github.com/CosmWasm/wasmvm/releases/download/$COSMWASM_VERSION/libwasmvm_muslc.$ARCH.a \
           -O /lib/libwasmvm_muslc.$ARCH.a && \
      wget -q https://github.com/CosmWasm/wasmvm/releases/download/$COSMWASM_VERSION/checksums.txt -O /tmp/checksums.txt && \
      sha256sum /lib/libwasmvm_muslc.$ARCH.a | grep $(grep libwasmvm_muslc.$ARCH /tmp/checksums.txt | cut -d' ' -f1); \
    else \
      echo "==> Skipping GitHub download (WASMVM_SOURCE=$WASMVM_SOURCE)"; \
    fi

# ---------------------------------------------------------
# Copy the source tree (everything) and build *statically*
# ---------------------------------------------------------
COPY . /code/

# ---------------------------------------------------------
# Prepare go.mod & wasmvm lib based on source mode
# ---------------------------------------------------------
RUN ARCH=$(uname -m) && \
    if [ "$WASMVM_SOURCE" = "local" ]; then \
      echo "==> Using local wasmvm library" && \
      # --- static lib ------------------------------------------------------- \
      if [ ! -f /code/build/wasmvm/libwasmvm_muslc.$ARCH.a ]; then \
        echo "ERROR: build/wasmvm/libwasmvm_muslc.$ARCH.a not found." && \
        echo "Run 'make docker-stage-zk' first to stage zk dependencies." && \
        exit 1; \
      fi && \
      cp /code/build/wasmvm/libwasmvm_muslc.$ARCH.a /lib/libwasmvm_muslc.$ARCH.a && \
      # --- go.mod: rewrite local replace paths to staged copies -------------- \
      sed -i 's|=> \.\./zk-wasmvm|=> /code/build/zk-deps/zk-wasmvm|g' /code/go.mod && \
      sed -i 's|=> \.\./zk-wasmd|=> /code/build/zk-deps/zk-wasmd|g'   /code/go.mod; \
    else \
      echo "==> Stripping local replace directives for standard build" && \
      # --- go.mod: remove the zk-local replace block so go uses upstream ----- \
      sed -i '/zk-circuit flavored wasmvm included in fork/d' /code/go.mod && \
      sed -i '/zk-circuit flavored wasmvm/d'                  /code/go.mod && \
      sed -i '/=> \.\.\/zk-wasmvm/d'                          /code/go.mod && \
      sed -i '/=> \.\.\/zk-wasmd/d'                           /code/go.mod; \
    fi

# force it to use static lib (from above) not standard libgo_cosmwasm.so file
RUN LEDGER_ENABLED=false BUILD_TAGS=muslc LINK_STATICALLY=true make build
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
