package ipfs

import (
	"bytes"
	"testing"

	mh "github.com/multiformats/go-multihash"
)

func TestCidV0RoundTrip(t *testing.T) {
	h, err := mh.Sum([]byte("TEST"), mh.SHA2_256, -1)
	if err != nil {
		t.Fatal(err)
	}
	c := NewCidV0(h)
	if c.Version() != 0 {
		t.Fatalf("version: got %d", c.Version())
	}
	if c.Type() != DagProtobuf {
		t.Fatalf("type: got 0x%x", c.Type())
	}

	s := c.String()
	if len(s) != 46 || s[:2] != "Qm" {
		t.Fatalf("unexpected CIDv0 string: %s", s)
	}

	parsed, err := Decode(s)
	if err != nil {
		t.Fatal(err)
	}
	if !c.Equals(parsed) {
		t.Fatalf("decode mismatch")
	}

	cast, err := Cast(c.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	if !c.Equals(cast) {
		t.Fatalf("cast mismatch")
	}
}

func TestCidV1RawRoundTrip(t *testing.T) {
	h, err := mh.Sum([]byte("TEST"), mh.SHA2_256, -1)
	if err != nil {
		t.Fatal(err)
	}
	c := NewCidV1(Raw, h)
	if c.Version() != 1 {
		t.Fatalf("version: got %d", c.Version())
	}

	parsed, err := Decode(c.String())
	if err != nil {
		t.Fatal(err)
	}
	if !c.Equals(parsed) {
		t.Fatalf("decode mismatch: %s vs %s", c, parsed)
	}
}

func TestPrefixSum(t *testing.T) {
	h, err := mh.Sum([]byte("foobar"), mh.SHA2_256, -1)
	if err != nil {
		t.Fatal(err)
	}
	want := NewCidV1(Raw, h)

	p := Prefix{Version: 1, Codec: Raw, MhType: mh.SHA2_256, MhLength: 32}
	got, err := p.Sum([]byte("foobar"))
	if err != nil {
		t.Fatal(err)
	}
	if !want.Equals(got) {
		t.Fatalf("prefix sum: got %s want %s", got, want)
	}
}

func TestCidFromBytesAndReader(t *testing.T) {
	h, err := mh.Sum([]byte("reader"), mh.SHA2_256, -1)
	if err != nil {
		t.Fatal(err)
	}
	c := NewCidV0(h)

	n, out, err := CidFromBytes(c.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	if n != c.ByteLen() || !c.Equals(out) {
		t.Fatalf("CidFromBytes mismatch")
	}

	n, out, err = CidFromReader(bytes.NewReader(c.Bytes()))
	if err != nil {
		t.Fatal(err)
	}
	if n != c.ByteLen() || !c.Equals(out) {
		t.Fatalf("CidFromReader mismatch")
	}
}

func TestParseIPFSPath(t *testing.T) {
	c, err := AddBytes([]byte("path-test"))
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := Parse("/ipfs/" + c.String())
	if err != nil {
		t.Fatal(err)
	}
	if !c.Equals(parsed) {
		t.Fatalf("Parse /ipfs/ path failed")
	}
}
