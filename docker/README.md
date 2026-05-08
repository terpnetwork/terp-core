# Local Terp

Here we have a way to spin up a local network in two commands, including a faucet for testing purposes.


## Build And Run
```sh
# builds the local terp binary 
docker buildx build --target localterp -t ghcr.io/terpnetwork/terp-core:v5.2.0-zk-localterp --load  .
# One‑liner that pulls the image (if not present) and starts it.
docker run --rm -it -p 26657:26657 -p 1317:1317 -p 8545:8545 -p 5000:5000 -p 9090:9090 ghcr.io/terpnetwork/terp-core:v5.2.0-zk-localterp
```

> notice that the difference between building the ~400MB docker image (containing the faucet & nodejs dependencies) and building the ~200MB production image is by specification of the `--target` flag:
>
> `--target localterp` for local terp\
> `--target runtime` for production images


### Overwriting Mnemonics Used
> To bring your own keys to validators and faucets, include the env vars in the docker run command:
>
> `-e VALIDATOR_MNEMONIC="validator mnemonic here"`\
>  or\
> `-e ACCOUNT_FAUCET_MNEMONIC="validator mnemonic here"`

## Using The Faucet

The faucet is exposed by default on `localhost:5000`

```sh
# check status
curl localhost:5000/status
# get tokens from faucet 
curl "http://localhost:5000/faucet?address=terp123abc"
# {"txhash":"4E108EEB9C0CE0984E930606E9B977914382E8624F978DA15EF1019EB39E233F"           
```
