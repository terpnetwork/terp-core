FROM golang:1.24-alpine AS go-builder

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

# ---------------------------------------------------------
# Pull in the exact wasmvm lib that the Cosmos SDK wants
# ---------------------------------------------------------
RUN ARCH=$(uname -m) && \
    WASMVM_VERSION=$(go list -m github.com/CosmWasm/wasmvm/v3 | awk '{print $2}') && \
    wget -q https://github.com/CosmWasm/wasmvm/releases/download/$WASMVM_VERSION/libwasmvm_muslc.$ARCH.a \
         -O /lib/libwasmvm_muslc.$ARCH.a && \
    wget -q https://github.com/CosmWasm/wasmvm/releases/download/$WASMVM_VERSION/checksums.txt -O /tmp/checksums.txt && \
    sha256sum /lib/libwasmvm_muslc.$ARCH.a | grep $(grep libwasmvm_muslc.$ARCH /tmp/checksums.txt | cut -d' ' -f1)

# ---------------------------------------------------------
# Copy the source tree (everything) and build *statically*
# ---------------------------------------------------------
COPY . /code/

# force it to use static lib (from above) not standard libgo_cosmwasm.so file
RUN LEDGER_ENABLED=false BUILD_TAGS=muslc LINK_STATICALLY=true make build
RUN echo "Ensuring binary is statically linked ..." \
  && (file /code/build/terpd | grep "statically linked")

# ---------------------------------------------------------
# 1️⃣  Runtime image – this is normal terpd binary
# ---------------------------------------------------------
FROM alpine:3.17 AS runtime

# Minimal set of runtime deps (ca‑certs is enough for HTTPS RPC)
RUN apk add --no-cache ca-certificates

COPY --from=go-builder /code/build/terpd /usr/local/bin/terpd

ENV HOME=/terpd
WORKDIR $HOME

# expose the usual Tendermint ports
EXPOSE 1317 26656 26657

CMD ["/usr/local/bin/terpd"]

# ---------------------------------------------------------
# 2️⃣  Localterp bootstrap image – binary + init scripts + tools
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

HEALTHCHECK --interval=5s --timeout=1s --retries=120 \
  CMD bash -c 'curl -sfm1 http://localhost:26657/status && \
               curl -s http://localhost:26657/status | jq -e "(.result.sync_info.latest_block_height | tonumber) > 0"'

ENTRYPOINT ["/code/bootstrap.sh"]