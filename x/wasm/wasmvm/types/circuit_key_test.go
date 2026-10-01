package types

import "testing"

func TestSplitCombinedStoreIDs(t *testing.T) {
	if CombinedStoreIDLen != 104 {
		t.Fatalf("CombinedStoreIDLen=%d want 104", CombinedStoreIDLen)
	}
	blob := make([]byte, CombinedStoreIDLen)
	for i := range blob {
		blob[i] = byte(i)
	}
	code, circuit, err := SplitCombinedStoreIDs(blob)
	if err != nil {
		t.Fatal(err)
	}
	if len(code) != ChecksumLen {
		t.Fatalf("code len %d", len(code))
	}
	if len(circuit) != CircuitKeyLen {
		t.Fatalf("circuit len %d", len(circuit))
	}
	if code[0] != 0 || circuit[0] != 32 || circuit[71] != 103 {
		t.Fatalf("slice bounds wrong")
	}
	_, _, err = SplitCombinedStoreIDs(blob[:64])
	if err == nil {
		t.Fatal("expected length error")
	}
}
