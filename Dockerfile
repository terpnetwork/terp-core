# docker build . -t terpnetwork/terpd:latest
# docker run --rm -it terpnetwork/terpd:latest /bin/sh
FROM golang:1.21-alpine AS go-builder 
ARG arch=x86_64

# this comes from standard alpine nightly file
#  https://github.com/rust-lang/docker-rust-nightly/blob/master/alpine3.12/Dockerfile
# with some changes to support our toolchain, etc
RUN set -eux; apk add --no-cache ca-certificates build-base;

RUN apk add git
# NOTE: add these to run with LEDGER_ENABLED=true
# RUN apk add libusb-dev linux-headers

WORKDIR /code
COPY . /code/
# See https://github.com/CosmWasm/wasmvm/releases

# Cosmwasm - Download correct libwasmvm version
RUN WASMVM_VERSION=$(go list -m github.com/CosmWasm/wasmvm | cut -d ' ' -f 2) && \
  wget https://github.com/CosmWasm/wasmvm/releases/download/$WASMVM_VERSION/libwasmvm_muslc.$(uname -m).a \
  -O /lib/libwasmvm_muslc.a && \
  # verify checksum
  wget https://github.com/CosmWasm/wasmvm/releases/download/$WASMVM_VERSION/checksums.txt -O /tmp/checksums.txt && \
  sha256sum /lib/libwasmvm_muslc.a | grep $(cat /tmp/checksums.txt | grep libwasmvm_muslc.$(uname -m) | cut -d ' ' -f 1)

# Copy the library you want to the final location that will be found by the linker flag `-lwasmvm_muslc`
RUN cp /lib/libwasmvm_muslc.${arch}.a /lib/libwasmvm_muslc.a

# force it to use static lib (from above) not standard libgo_cosmwasm.so file
RUN LEDGER_ENABLED=false BUILD_TAGS=muslc LINK_STATICALLY=true make build
RUN echo "Ensuring binary is statically linked ..." \
  && (file /code/build/terpd | grep "statically linked")

# --------------------------------------------------------

FROM alpine:3.16

COPY --from=go-builder /code/build/terpd /usr/bin/terpd

COPY docker/* /opt/
RUN chmod +x /opt/*.sh

WORKDIR /opt

# rest server
EXPOSE 1317
# tendermint p2p
EXPOSE 26656
# tendermint rpc
EXPOSE 26657

CMD ["/usr/bin/terpd", "version"]