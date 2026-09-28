//go:build v64

package keepers

// MountDestStores stays true: dest trees are the live keeper stores after B.
const MountDestStores = true

// KeepersOnDest maps module StoreKey constants onto dest b3-* keys.
// Live SHA-256 migratable names are not mounted.
const KeepersOnDest = true

// MountHooksStore is false. v6.3 already deleted hooks-for-ibc.
const MountHooksStore = false
