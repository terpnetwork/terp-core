package ics23

import (
	"strconv"
	"testing"
)

func BenchmarkDoHash(b *testing.B) {
	ops := []struct {
		name string
		op   HashOp
	}{
		{"sha256", HashOp_SHA256},
		{"blake2s", HashOp_BLAKE2S_256},
		{"blake2b256", HashOp_BLAKE2B_256},
		{"blake3", HashOp_BLAKE3},
	}
	sizes := []int{32, 64, 75, 256}
	for _, size := range sizes {
		pre := make([]byte, size)
		for i := range pre {
			pre[i] = byte(i)
		}
		for _, tc := range ops {
			b.Run(tc.name+"/"+strconv.Itoa(size), func(b *testing.B) {
				b.SetBytes(int64(size))
				b.ReportAllocs()
				for i := 0; i < b.N; i++ {
					_, err := doHash(tc.op, pre)
					if err != nil {
						b.Fatal(err)
					}
				}
			})
		}
	}
}
