# Local Terp

Spin up a local Terp network with a built-in faucet.

## Build & Run

```sh
# Build the localterp image (~400MB, includes Node.js + faucet)
docker buildx build --target localterp -t terpnetwork/terp-core:localterp --load .

# Run it
docker run --rm -it -p 26657:26657 -p 1317:1317 -p 5000:5000 -p 9090:9090 terpnetwork/terp-core:localterp
```

> `--target localterp` = dev image with faucet (~400MB)
> `--target runtime` = production image, no faucet (~200MB)

## Pre-funded Keys

| Key | Purpose |
|-----|---------|
| `validator` | Genesis validator |
| `a` | Default faucet source |
| `b`, `c`, `d` | Test accounts |

All funded with 1e18 uterp + 1e18 uthiol at genesis.

## Faucet API

Exposed on port 5000.

```sh
# Check status
curl localhost:5000/status
# {"faucet_address":"terp1...","amount":"1000000000","denoms":["uterp","uthiol"]}

# Get tokens
curl "localhost:5000/faucet?address=terp1youraddr"
# {"txhash":"4E108E..."}
```

### Faucet Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `FAUCET_WALLET_NAME` | `a` | Keyring key to send from |
| `FAUCET_AMOUNT` | `1000000000` | Amount per denom per request |
| `DENOMS` | `uterp,uthiol` | Comma-separated denoms |

## Using with ict-rs

ict-rs has built-in support for the localterp faucet. Use `TestEnv::terp_localterp_config()` to get a chain config that automatically creates a faucet key, exposes port 5000, and starts the faucet after the chain produces blocks.

```rust
use ict_rs::prelude::*;
use ict_rs::testing::{setup_chain, TestEnv};

let cfg = TestEnv::terp_localterp_config();
let tc = setup_chain("my_test", cfg).await?;

// Fund any address at runtime
tc.faucet_fund("terp1abc...").await?;
```

See `terp-rs/crates/public/ict-rs/README.md` for full documentation.
