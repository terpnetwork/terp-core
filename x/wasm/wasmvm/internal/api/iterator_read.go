package api

import "github.com/CosmWasm/wasmvm/v3/types"

// readIteratorItem returns the current key and value, then steps forward.
//
// cosmos-sdk prefixIterator.Error returns "invalid prefixIterator" whenever
// Valid is false, including after a successful Next off the last key. That is
// exhaustion. CosmWasm prefix scans (collection config, price tiers) hit it
// on the last record. A real iterator error is only one reported while Valid
// is still true.
func readIteratorItem(iter types.Iterator) (key, value []byte, ok bool, err error) {
	if iter == nil || !iter.Valid() {
		return nil, nil, false, nil
	}
	key = iter.Key()
	value = iter.Value()
	if err = iter.Error(); err != nil {
		return nil, nil, false, err
	}
	iter.Next()
	if !iter.Valid() {
		return key, value, true, nil
	}
	if err = iter.Error(); err != nil {
		return nil, nil, false, err
	}
	return key, value, true, nil
}

// readIteratorPart is readIteratorItem for key-only or value-only scans.
func readIteratorPart(iter types.Iterator, part func(types.Iterator) []byte) (out []byte, ok bool, err error) {
	if iter == nil || !iter.Valid() {
		return nil, false, nil
	}
	out = part(iter)
	if err = iter.Error(); err != nil {
		return nil, false, err
	}
	iter.Next()
	if !iter.Valid() {
		return out, true, nil
	}
	if err = iter.Error(); err != nil {
		return nil, false, err
	}
	return out, true, nil
}
