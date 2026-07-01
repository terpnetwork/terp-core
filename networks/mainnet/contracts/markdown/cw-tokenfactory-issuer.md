## Store WASM Code

This uploads the code for cw-tokenfactory-issuer

The source code is available at https://github.com/DA0-DA0/dao-contracts/tree/development/contracts/external/cw-tokenfactory-issuer v2.4.0

### Compile Instructions

```sh
docker run --rm -v "$(pwd)":/code --platform linux/amd64 \
	--mount type=volume,source="$(basename "$(pwd)")_cache",target=/code/target \
	--mount type=volume,source=registry_cache,target=/usr/local/cargo/registry \
	cosmwasm/workspace-optimizer:0.12.13
```

This results in the following SHA256 checksum:

```
1768e04915b7de876c4352112c1b19bdf1a6f8590cf61626113aae521ba66ee1  cw_tokenfactory_issuer.wasm
```

### Verify On-chain Contract

```sh
terpd  q gov proposal $id --output json \
| jq -r '.content.wasm_byte_code' \
| base64 -d \
| gzip -dc \
| sha256sum

```

### Verify Local Contract

```
sha256sum artifacts/cw-tokenfactory-issuer.wasm
```