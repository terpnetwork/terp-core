## Store WASM Code

This uploads the code for cw721-fixed-price

https://github.com/CosmWasm/cw-nfts/tree/main/contracts/cw721-fixed-price v1.8.0

### Compile Instructions

```sh
docker run --rm -v "$(pwd)":/code --platform linux/amd64 \
	--mount type=volume,source="$(basename "$(pwd)")_cache",target=/code/target \
	--mount type=volume,source=registry_cache,target=/usr/local/cargo/registry \
	cosmwasm/workspace-optimizer:0.12.13
```

This results in the following SHA256 checksum:

```
a6e3416299bc89214d8016ee7026a7f2e46d1bcc8512818ed4698f900db6c479  cw721_fixed_price-aarch64.wasm
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
sha256sum artifacts/cw721_fixed_price-aarch64.wasm
```