## Store WASM Code

This uploads the code for cw721-roles

https://github.com/DA0-DA0/dao-contracts/tree/development/contracts/external/cw721-roles v2.4.0

### Compile Instructions

```sh
docker run --rm -v "$(pwd)":/code --platform linux/amd64 \
	--mount type=volume,source="$(basename "$(pwd)")_cache",target=/code/target \
	--mount type=volume,source=registry_cache,target=/usr/local/cargo/registry \
	cosmwasm/workspace-optimizer:0.12.13
```

This results in the following SHA256 checksum:

```
bd6886b33d37801deb2130ad78db3e48a7a592dd265600d459888ffaf49cd128  cw721_roles.wasm
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
sha256sum artifacts/cw721-roles.wasm
```