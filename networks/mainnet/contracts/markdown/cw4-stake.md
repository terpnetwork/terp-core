## Store WASM Code

This uploads the code for cw4-stake

The source code is available at https://github.com/CosmWasm/cw-plus/tree/main/contracts/cw4-stake v1.1.2

### Compile Instructions

```sh
docker run --rm -v "$(pwd)":/code --platform linux/amd64 \
	--mount type=volume,source="$(basename "$(pwd)")_cache",target=/code/target \
	--mount type=volume,source=registry_cache,target=/usr/local/cargo/registry \
	cosmwasm/workspace-optimizer:0.12.13
```

This results in the following SHA256 checksum:

```
8de5054ca3a07e102af78c58031e72c13087ce520521414eaed1b388948a68c6  cw4_stake.wasm
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
sha256sum artifacts/cw4-stake.wasm
```