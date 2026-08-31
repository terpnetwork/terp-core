// Package iavlv2 is experimental support for github.com/cosmos/iavl/v2.
//
// It is not wired into NewTerpApp or BaseApp. Live CommitMultiStore remains
// IAVL v1 via store/v2 (see docs/IAVL_V2.md).
package iavlv2

import (
	"fmt"

	iavl "github.com/cosmos/iavl/v2"
)

// OpenTree opens an IAVL v2 Tree backed by SQLite files under dir
// (changelog.sqlite + tree.sqlite). Caller must Close the tree.
// Hashing defaults to SHA-256; pass TreeOptions{UseBlake3: true} via
// OpenTreeWithOptions for BLAKE3-256 node hashes.
func OpenTree(dir string) (*iavl.Tree, error) {
	return OpenTreeWithOptions(dir, iavl.DefaultTreeOptions())
}

// OpenTreeWithOptions is OpenTree with TreeOptions (UseBlake3, checkpoints).
func OpenTreeWithOptions(dir string, opts iavl.TreeOptions) (*iavl.Tree, error) {
	if dir == "" {
		return nil, fmt.Errorf("iavlv2: empty sqlite dir")
	}
	pool := iavl.NewNodePool()
	sql, err := iavl.NewSqliteDb(pool, iavl.SqliteDbOptions{
		Path:     dir,
		MmapSize: 64 * 1024 * 1024,
	})
	if err != nil {
		return nil, err
	}
	return iavl.NewTree(sql, pool, opts), nil
}

// OpenMultiTree mounts one SQLite tree per store key under root.
func OpenMultiTree(root string, storeKeys []string) (*iavl.MultiTree, error) {
	if root == "" {
		return nil, fmt.Errorf("iavlv2: empty multitree root")
	}
	mt := iavl.NewMultiTree(root, iavl.DefaultTreeOptions())
	for _, key := range storeKeys {
		if err := mt.MountTree(key); err != nil {
			_ = mt.Close()
			return nil, err
		}
	}
	return mt, nil
}
