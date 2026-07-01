## Store WASM Code

This uploads the code for cw-vesting
The source code is available at https://github.com/DA0-DA0/dao-contracts/tree/development/contracts/external/cw-vesting v2.4.0

### Compile Instructions

```sh
docker run --rm -v "$(pwd)":/code --platform linux/amd64 \
	--mount type=volume,source="$(basename "$(pwd)")_cache",target=/code/target \
	--mount type=volume,source=registry_cache,target=/usr/local/cargo/registry \
	cosmwasm/workspace-optimizer:0.12.13
```

This results in the following SHA256 checksum:

```
3c5f8b385a1653a2c1dc806e4fdddb81c25bc53466f49c1d22f7880d08fd0d93 cw_vesting.wasm
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
sha256sum artifacts/cw-vesting.wasm
```