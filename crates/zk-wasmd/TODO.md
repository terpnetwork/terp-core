# MULTI CIRCUIT SUPPORT

- wire in new zk retrieval through wasmvm & wasmd
- tune cache layer to support new file design
- implement test and helpers for handling hash of keys and serialization and caching functionality
- tune headstash 
<!-- - Circuit That Prooves Stuff:
    - identifiers:
        - checksums of files that consist the raw bytes:
             - VkChecksumKey = H(cs||vk||footer)
             - ParamChecksumKey = H(param)
             - ZkCircuitChecksumKey(zk_id) = H(ParamChecksumKey||VkChecksumKey)
 -->


# STORE
- pass checksum of verifying key in proof instance verification request for modular verification support.
- add byte length validation macro forfor instances upon proof request
- middleware for tokengate/marketplace for circuit revenue use
