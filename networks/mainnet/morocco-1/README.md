# Terp Network - Mainnet


## Syncing a node

For a complete description of how to sync a node, including all upgrades, check out the [Terp Network Documentation site]().

In the `morocco-1` folder you can find a number of upgrade files in all caps.

## Original launch docs


_Planned Start Time: April10th  at 12:00 UTC._

**Genesis File**

[Genesis File](/morocco-1/genesis.json):

```bash
   curl -s  https://raw.githubusercontent.com/terpnetwork/mainnet/main/morocco-1/genesis.json > ~/.terp/config/genesis.json
```

**Genesis sha256**

```bash
sha256sum ~/.terp/config/genesis.json
ab6c68c50d45cb9a145edf6b37c05cb9eefc2a0488d08498b8f827c2471ba843 genesis.json
```

**terpd version**

```bash
$ terpd version --long
commit: 22f9b2992a9a113bff7b923f7f39c46ae0f61857
cosmos_sdk_version: v0.47.1
go: go version go1.20.3 linux/amd64
name: terp
server_name: terpd
version: 1.0.0
```
**Seed node**

[Full seed nodes list](/morocco-1/seeds.txt).

```
c71e63b5da517984d55d36d00dc0dc2413d0ce03@seed.terp.network:26656
```

## Setup

**Prerequisites:** Make sure to have [Golang >=1.20.3](https://golang.org/).

#### Build from source

You need to ensure your gopath configuration is correct. If the following **'make'** step does not work then you might have to add these lines to your .profile or .zshrc in the users home folder:

```bash
export GOROOT=/usr/local/go
export GOPATH=$HOME/go
export GO111MODULE=on
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin
```

```bash
git clone https://github.com/terpnetwork/terp-core
cd terp-core
git checkout v1.0.0
make build && make install
```

This will build and install `terp` binary into `$GOBIN`.

### Minimum hardware requirements

- 16-64GB RAM
- 500GB of disk space
- 1.4 GHz amd64 CPU

### Learn more

- [Terp Documentation](https://docs.terp.network)
- [Terp Network Community Discord](https://discord.gg/9mFZc4XEDA)
- [Terp Network Community Telegram](https://t.me/+FuFi63JcwuEzNmVh)
