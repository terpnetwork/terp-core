## Store WASM Code

This uploads the code for cw2981-royalties

https://github.com/CosmWasm/cw-nfts/tree/main/contracts/cw2981-royalties v1.8.0

### Compile Instructions

```sh
docker run --rm -v "$(pwd)":/code --platform linux/amd64 \
	--mount type=volume,source="$(basename "$(pwd)")_cache",target=/code/target \
	--mount type=volume,source=registry_cache,target=/usr/local/cargo/registry \
	cosmwasm/workspace-optimizer:0.12.13
```

This results in the following SHA256 checksum:

```
71f4a24c80347637d50b8a5911f432ee1b20b12e3765dfc2149d12d6b09dd0c2  cw2981_royalties.wasm
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
sha256sum artifacts/cw2981-royalties.wasm
```