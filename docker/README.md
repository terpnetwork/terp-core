# Docker Tools

## Compile Image
```sh
# builds the normal binary
docker buildx build --target runtime   -t terpnetwork/terp-core:latest .
```
## Local Terp
```sh
# builds the local terp binary 
docker buildx build --target localterp -t terpnetwork/terp-core:localterp --load  .
# One‑liner that pulls the image (if not present) and starts it.
docker run --rm -it -p 26657:26657 -p 1317:1317 -p 8545:8545 terpnetwork/terp-core:localterp
```


