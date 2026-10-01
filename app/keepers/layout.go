//go:build !v64 && !v63pre

package keepers

// MountDestStores is true on the v6.3.0 ELF. Dest b3-* trees are Added at
// plan v6.3. Keepers stay on live SHA-256 names until the v6.4.0 ELF.
const MountDestStores = true

// KeepersOnDest is false until the v6.4.0 ELF.
const KeepersOnDest = false

// MountHooksStore is false on v6.3.0. The upgrade loader deletes hooks-for-ibc
// before the handler copies dest stores.
const MountHooksStore = false
