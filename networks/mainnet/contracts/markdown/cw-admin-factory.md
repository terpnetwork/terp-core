## Store WASM Code

This uploads the code for cw-admin-factory

The source code is available at https://github.com/DA0-DA0/dao-contracts/tree/development/contracts/external/cw-admin-factory v2.4.0

### Compile Instructions

```sh
docker run --rm -v "$(pwd)":/code --platform linux/amd64 \
	--mount type=volume,source="$(basename "$(pwd)")_cache",target=/code/target \
	--mount type=volume,source=registry_cache,target=/usr/local/cargo/registry \
	cosmwasm/workspace-optimizer:0.12.13
```

This results in the following SHA256 checksum:

```
d238b7000fb7803871c1e5d1d5143388386fd5ebcfe941572422970849ca3328  cw_admin_factory.wasm
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
sha256sum artifacts/cw-admin-factory.wasm
```