package iavlv2

import iavl "github.com/cosmos/iavl/v2"

// Ingest writes kvs into a new IAVL v2 sqlite tree and returns the root hash.
// useBlake3 selects BLAKE3-256; false is SHA-256. Caller owns dir.
func Ingest(dir string, kvs [][2][]byte, useBlake3 bool) ([]byte, error) {
	opts := iavl.DefaultTreeOptions()
	opts.UseBlake3 = useBlake3
	tree, err := OpenTreeWithOptions(dir, opts)
	if err != nil {
		return nil, err
	}
	defer tree.Close()
	for _, kv := range kvs {
		if _, err := tree.Set(kv[0], kv[1]); err != nil {
			return nil, err
		}
	}
	hash, _, err := tree.SaveVersion()
	return hash, err
}
