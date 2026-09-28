//go:build v63pre

package keepers

// v63pre is the local-genesis Cosmovisor genesis ELF (post-v6.2 shape):
// no dest trees, no v6.3 handler. Cosmovisor swaps to the v6.3.0 ELF at halt.
const MountDestStores = false
const KeepersOnDest = false

// MountHooksStore keeps the live ibc-hooks KV so a v6.2 snapshot still opens.
const MountHooksStore = true
