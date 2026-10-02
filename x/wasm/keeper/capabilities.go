package keeper

// BuiltInCapabilities returns all capabilities currently supported by this version of x/wasm.
// See also https://github.com/CosmWasm/cosmwasm/blob/main/docs/CAPABILITIES-BUILT-IN.md.
//
// Use this directly or together with your chain's custom capabilities (if any):
//
//	append(wasmkeeper.BuiltInCapabilities(), "token_factory")
func BuiltInCapabilities() []string {
	return []string{
		"iterator",
		"staking",
		"stargate",
		"cosmwasm_1_1",
		"cosmwasm_1_2",
		"cosmwasm_1_3",
		"cosmwasm_1_4",
		"cosmwasm_2_0",
		"cosmwasm_2_1",
		"cosmwasm_2_2",
		"ibc2",
		"bulk_memory",
		// BN254 is the BN256 / alt_bn128 host (bn254_add, bn254_scalar_mul, bn254_pairing_equality).
		"bn254",
		// BLAKE2b-256 and BLAKE3-256 (blake2b_256, blake3_256).
		"hash_blake",
		// Poseidon Pasta (poseidon_hash_pallas, poseidon_hash_vesta) and poseidon377.
		"hash_poseidon",
		// RedPallas and RedJubjub spend-auth and binding verify.
		"redpallas",
	}
}
