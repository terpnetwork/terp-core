package api

import "testing"

func FuzzCopyU8Slice(f *testing.F) {
	f.Add([]byte(nil))
	f.Add([]byte{})
	f.Add([]byte{0})
	f.Add([]byte("abc"))
	f.Add(make([]byte, 1024))
	f.Fuzz(func(t *testing.T, data []byte) {
		out := copyU8SliceFromBytes(data)
		if data == nil {
			if out != nil {
				t.Fatalf("nil input should copy to nil, got %v", out)
			}
			return
		}
		if string(out) != string(data) {
			t.Fatalf("%q != %q", out, data)
		}
	})
}

func FuzzMakeViewRoundTrip(f *testing.F) {
	f.Add([]byte("k"))
	f.Add([]byte{})
	f.Fuzz(func(t *testing.T, key []byte) {
		got := copyU8SliceFromBytes(key)
		if key == nil {
			if got != nil {
				t.Fatalf("expected nil")
			}
			return
		}
		if string(got) != string(key) {
			t.Fatalf("%q != %q", got, key)
		}
	})
}
