## Store WASM Code

This uploads the code for cw721-base

https://github.com/CosmWasm/cw-nfts/tree/main/contracts/cw721-base v1.8.0

### Compile Instructions

```sh
docker run --rm -v "$(pwd)":/code --platform linux/amd64 \
	--mount type=volume,source="$(basename "$(pwd)")_cache",target=/code/target \
	--mount type=volume,source=registry_cache,target=/usr/local/cargo/registry \
	cosmwasm/workspace-optimizer:0.12.13
```

This results in the following SHA256 checksum:

```
ebaac38567cb8d02c94a62886ae976aeedf3087f568ed18b5c7d588a8f5a6d52  cw721_base.wasm
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
sha256sum artifacts/cw721-base.wasm
```