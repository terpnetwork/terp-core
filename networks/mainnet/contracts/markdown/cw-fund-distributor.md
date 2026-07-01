## Store WASM Code

This uploads the code for cw-fund-distributor

The source code is available at https://github.com/DA0-DA0/dao-contracts/tree/development/contracts/external/cw-fund-distributor v2.4.0

### Compile Instructions

```sh
docker run --rm -v "$(pwd)":/code --platform linux/amd64 \
	--mount type=volume,source="$(basename "$(pwd)")_cache",target=/code/target \
	--mount type=volume,source=registry_cache,target=/usr/local/cargo/registry \
	cosmwasm/workspace-optimizer:0.12.13
```

This results in the following SHA256 checksum:

```
c09df1f82a3972536f68697c86f6c3facc3b810b862fd43f8045379008aba0d8  cw_fund_distributor.wasm
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
sha256sum artifacts/cw-fund-distributor.wasm
```