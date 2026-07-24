package ipfs

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// Golden vector: networks/upgrades/v520/draft_metadata_v520.json was added
// with classic `ipfs add` and recorded in draft_proposal.json as:
//
//	ipfs://QmZ2wdFVz3tTWSJdLNtLCZeksSkvGHo6F7GYSffR9zazv1
const (
	v520MetadataCID = "QmZ2wdFVz3tTWSJdLNtLCZeksSkvGHo6F7GYSffR9zazv1"
	v520Metadata    = `{
 "title": "V520 - D-Camphene",
 "authors": [
  "returniflost"
 ],
 "summary": "bug fixes and tuning",
 "details": "sets default tokenfactory params, wires in ibcwasm codec, fixes old drift of x/distr module appstate from x/staking's",
 "proposal_forum_url": "https://discord.terp.network",
 "vote_option_context": "yes,no,abstain,veto"
}`
)

func TestAddBytes_V520MetadataGolden(t *testing.T) {
	c, err := AddBytes([]byte(v520Metadata))
	if err != nil {
		t.Fatalf("AddBytes: %v", err)
	}
	if got := c.String(); got != v520MetadataCID {
		t.Fatalf("CID mismatch\n got:  %s\n want: %s", got, v520MetadataCID)
	}
	if c.Version() != 0 {
		t.Fatalf("expected CIDv0, got version %d", c.Version())
	}
	if c.Type() != DagProtobuf {
		t.Fatalf("expected dag-pb codec, got 0x%x", c.Type())
	}
}

func TestAddBytes_V520MetadataMatchesRepoFile(t *testing.T) {
	// Prefer live file if present (catches accidental reformatting of the golden).
	path := filepath.Join("..", "..", "networks", "upgrades", "v520", "draft_metadata_v520.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Skipf("repo metadata file not available: %v", err)
	}
	// File may or may not end with newline; golden content above has no trailing newline.
	data = bytes.TrimSuffix(data, []byte{'\n'})
	if !bytes.Equal(data, []byte(v520Metadata)) {
		t.Fatalf("repo draft_metadata_v520.json diverges from embedded golden vector")
	}

	got, err := AddBytesString(data)
	if err != nil {
		t.Fatal(err)
	}
	if got != v520MetadataCID {
		t.Fatalf("got %s want %s", got, v520MetadataCID)
	}
}

func TestAddBytes_EmptyFile(t *testing.T) {
	// Empty UnixFS file (Type=File, Data="", filesize=0) CIDv0.
	// (Distinct from empty-directory CID QmUNLLsPACCz1vLxQVkXqqLX5R1X345qqfHbsf67hvA3Nn.)
	const want = "QmaRwA91m9Rdfaq9u3FH1fdMVxw1wFPjKL38czkWMxh3KB"
	got, err := AddBytesString(nil)
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("empty file CID: got %s want %s", got, want)
	}
}

func TestAddBytes_Hello(t *testing.T) {
	// Single-block UnixFS file for the bytes "hello" (same layout as V520 golden).
	const want = "QmWfVY9y3xjsixTgbd9AorQxH7VtMpzfx2HaWtsoUYecaX"
	got, err := AddBytesString([]byte("hello"))
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("hello CID: got %s want %s", got, want)
	}
}

func TestAddBytes_RejectsOversized(t *testing.T) {
	big := make([]byte, DefaultChunkSize+1)
	_, err := AddBytes(big)
	if err == nil {
		t.Fatal("expected error for oversized input")
	}
}

func TestAddBytes_NotRawOrDagJSON(t *testing.T) {
	// Document that raw multihash / DagJSON wrappers are NOT what `ipfs add` returns.
	data := []byte(v520Metadata)
	c, err := AddBytes(data)
	if err != nil {
		t.Fatal(err)
	}
	if c.String() == "QmZSfjoifMgVoZy3WH7u9iDRHMM8rexpW2TSvhTopicqpd" {
		t.Fatal("AddBytes returned raw-content CIDv0; should be UnixFS-wrapped")
	}
	if got := c.String(); got != v520MetadataCID {
		t.Fatalf("got %s want %s", got, v520MetadataCID)
	}
}

func TestAddBytes_RoundTripParse(t *testing.T) {
	c, err := AddBytes([]byte("roundtrip"))
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := Decode(c.String())
	if err != nil {
		t.Fatal(err)
	}
	if !c.Equals(parsed) {
		t.Fatalf("decode mismatch: %s vs %s", c, parsed)
	}
}
