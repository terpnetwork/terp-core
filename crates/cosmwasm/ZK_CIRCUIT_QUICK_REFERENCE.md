# CosmWasm ZK Circuit - Quick Reference Guide

## Documentation Map

### For Circuit Developers

Start here for implementing circuits:

1. **[Circuit Developer Guide](./ZK_COSMWASM_CIRCUIT_MACRO.md)**
    - File structure and architecture
    - How to use the macro
    - Parsing and validation
    - Basic circuit examples
    - Code generation
    - Testing strategies
    - Deployment workflow
    - Troubleshooting

### For Integration/Infrastructure

Understand the serialization and VM integration:

1. **[Serialization Format](./ZK_CIRCUIT_SERIALIZATION_FORMAT.md)** - Byte-level details
   - Complete format specification
   - Validation rules
   - Deserialization process
   - Hash computation

2. **[Storage and Caching](./ZK_STORAGE_AND_CACHING.md)** - VM caching architecture
   - Three-tier cache hierarchy
   - Memory management
   - Circuit lifecycle
   - Performance optimization

3. **[Proof Verification Architecture](./ZK_PROOF_VERIFICATION_ARCHITECTURE.md)** - Multi-circuit support
   - ZKid-based circuit selection
   - VM cache integration
   - Host import implementation
   - Memory management

### For Existing Code Reference

See the current implementation:

1. **[packages/vm/src/zk.rs](./packages/vm/src/zk.rs)** - VM ZK layer
   - Current structures
   - Integration points

---
