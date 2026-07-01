## Store WASM Code

This uploads the code for cw4-group

The source code is available at https://github.com/CosmWasm/cw-plus/tree/main/contracts/cw4-group v1.1.2

### Compile Instructions

```sh
docker run --rm -v "$(pwd)":/code --platform linux/amd64 \
	--mount type=volume,source="$(basename "$(pwd)")_cache",target=/code/target \
	--mount type=volume,source=registry_cache,target=/usr/local/cargo/registry \
	cosmwasm/workspace-optimizer:0.12.13
```

This results in the following SHA256 checksum:

```
dd2216f1114fc68bc4c043701b02e55ce3e5598cdeb616985388215a400db277  cw4_group.wasm
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
sha256sum artifacts/cw4-group.wasm
```