## Store WASM Code

This uploads the code for cw-tokenswap

The source code is available at https://github.com/DA0-DA0/dao-contracts/tree/development/contracts/external/cw-token-swap v2.4.0

### Compile Instructions

```sh
docker run --rm -v "$(pwd)":/code --platform linux/amd64 \
	--mount type=volume,source="$(basename "$(pwd)")_cache",target=/code/target \
	--mount type=volume,source=registry_cache,target=/usr/local/cargo/registry \
	cosmwasm/workspace-optimizer:0.12.13
```

This results in the following SHA256 checksum:

```
a48407e46cf819d3073a4dff1c013fb008da49da1327ffffbb1d79ca89806520  cw_token_swap.wasm
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
sha256sum artifacts/cw-tokenswap.wasm
```