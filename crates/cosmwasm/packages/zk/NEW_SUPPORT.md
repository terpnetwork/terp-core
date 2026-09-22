# NEW ZK SUPPORT 

## BINIUS 64
- will require us to parse speciic circuit contstraint system via its verifier:
    https://github.com/binius-zk/binius64/blob/main/crates/verifier/src/lib.rs

Verifier parses constraint system to https://github.com/binius-zk/binius64/blob/main/crates/verifier/src/verify.rs#L274

## Plonky 3

#


reuse params for circuit types:
- upload params

```md
        // TODOTODO: re-add cs len, manually grab cs from bytes, use load_with_cs to avoid needing to guard and desrialize 

## utilizing vm storage instead of query 

right now vm makes grpc query to sdk requesting for the circuit we have stored to state, crossing ffi boundary twice, for action we can derive inside vm state always

- requires use to mirror get_module function, but with use of our circuits

## Reusing Params

- ensure we are not storing keys twice (in vm and in app-state)
- reuse params bytes by loading to files params labeled with (curve_k_params.bin)
    - extend cache to support these bytes and load as needed.
    - load with params
