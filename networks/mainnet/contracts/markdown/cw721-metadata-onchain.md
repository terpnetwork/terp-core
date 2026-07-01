## Store WASM Code

This uploads the code for cw721-metadata-onchain

https://github.com/CosmWasm/cw-nfts/tree/main/contracts/cw721-metadata-onchain v1.8.0

### Compile Instructions

```sh
docker run --rm -v "$(pwd)":/code --platform linux/amd64 \
	--mount type=volume,source="$(basename "$(pwd)")_cache",target=/code/target \
	--mount type=volume,source=registry_cache,target=/usr/local/cargo/registry \
	cosmwasm/workspace-optimizer:0.12.13
```

This results in the following SHA256 checksum:

```
c582189243943fc8884d9022dc932b7e6d5bbe9b90fd293977dcc0ffffec0225  cw721_metadata_onchain-aarch64.wasm
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
sha256sum artifacts/cw721_metadata_onchain-aarch64.wasm
```