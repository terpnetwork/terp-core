//go:build v63pre

package keepers

// v63pre is the local-genesis Cosmovisor genesis ELF (post-v6.2 shape):
// no dest trees, no v6.3 handler. Cosmovisor swaps to the v6.3.0 ELF at halt.
const MountDestStores = false
const KeepersOnDest = false
