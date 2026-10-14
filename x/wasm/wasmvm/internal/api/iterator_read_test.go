package api

import (
	"errors"
	"testing"

	"github.com/CosmWasm/wasmvm/v3/types"
)

// prefixIter matches cosmos-sdk prefixIterator: Error is set for the whole
// time Valid is false, including a normal end of range.
type prefixIter struct {
	keys [][]byte
	vals [][]byte
	i    int
}

func (p *prefixIter) Domain() ([]byte, []byte) { return nil, nil }
func (p *prefixIter) Valid() bool              { return p.i < len(p.keys) }
func (p *prefixIter) Next() {
	if p.i < len(p.keys) {
		p.i++
	}
}
func (p *prefixIter) Key() []byte   { return p.keys[p.i] }
func (p *prefixIter) Value() []byte { return p.vals[p.i] }
func (p *prefixIter) Error() error {
	if !p.Valid() {
		return errors.New("invalid prefixIterator")
	}
	return nil
}
func (p *prefixIter) Close() error { return nil }

var _ types.Iterator = (*prefixIter)(nil)

func TestPrefixScanLastKeyIsNotAnError(t *testing.T) {
	// SVG collection config and a single price tier are one-key prefix ranges.
	iter := &prefixIter{
		keys: [][]byte{[]byte("svg_collection"), []byte("price_tier")},
		vals: [][]byte{[]byte("cfg"), []byte("tier")},
	}
	var got []string
	for {
		k, v, ok, err := readIteratorItem(iter)
		if err != nil {
			t.Fatalf("prefix scan: %v", err)
		}
		if !ok {
			break
		}
		got = append(got, string(k)+"="+string(v))
	}
	if len(got) != 2 || got[0] != "svg_collection=cfg" || got[1] != "price_tier=tier" {
		t.Fatalf("scan = %#v", got)
	}
}

func TestPrefixScanRealErrorWhileValid(t *testing.T) {
	iter := &brokenIter{}
	_, _, _, err := readIteratorItem(iter)
	if err == nil || err.Error() != "db closed" {
		t.Fatalf("err = %v", err)
	}
}

type brokenIter struct{}

func (b *brokenIter) Domain() ([]byte, []byte) { return nil, nil }
func (b *brokenIter) Valid() bool              { return true }
func (b *brokenIter) Next()                    {}
func (b *brokenIter) Key() []byte              { return []byte("k") }
func (b *brokenIter) Value() []byte            { return []byte("v") }
func (b *brokenIter) Error() error             { return errors.New("db closed") }
func (b *brokenIter) Close() error             { return nil }
