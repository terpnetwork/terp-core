package hash

import (
	"testing"

	"github.com/zeebo/blake3"
)

var blake3Sink []byte

func benchPayload(size int) []byte {
	buf := make([]byte, size)
	for i := range buf {
		buf[i] = byte(i)
	}
	return buf
}

func BenchmarkBLAKE3Ops(b *testing.B) {
	sizes := []int{32, 64, 256, 512, 1024, 4096}

	for _, size := range sizes {
		payload := benchPayload(size)

		b.Run("Sum256/"+itoa(size), func(b *testing.B) {
			b.SetBytes(int64(size))
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				sum := blake3.Sum256(payload)
				blake3Sink = sum[:]
			}
		})

		b.Run("NewWriteSum/"+itoa(size), func(b *testing.B) {
			b.SetBytes(int64(size))
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				h := blake3.New()
				_, _ = h.Write(payload)
				blake3Sink = h.Sum(nil)
			}
		})

		b.Run("ResetWriteSum/"+itoa(size), func(b *testing.B) {
			b.SetBytes(int64(size))
			b.ReportAllocs()
			h := blake3.New()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				h.Reset()
				_, _ = h.Write(payload)
				blake3Sink = h.Sum(nil)
			}
		})

		b.Run("PooledResetWriteSum/"+itoa(size), func(b *testing.B) {
			b.SetBytes(int64(size))
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				h := getBLAKE3()
				_, _ = h.Write(payload)
				blake3Sink = h.Sum(nil)
				putBLAKE3(h)
			}
		})
	}
}

func BenchmarkIAVLHasherOps(b *testing.B) {
	key := []byte("benchmark-key")
	value := benchPayload(100)
	left := make([]byte, HashSize)
	right := make([]byte, HashSize)

	hashers := []struct {
		name   string
		hasher Hasher
	}{
		{"blake3", NewBLAKE3Hasher()},
		{"sha256", NewSHA256Hasher()},
		{"poseidon", NewPoseidonHasher()},
	}

	for _, h := range hashers {
		h := h
		b.Run(h.name+"/HashValue", func(b *testing.B) {
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				blake3Sink = h.hasher.HashValue(value)
			}
		})
		b.Run(h.name+"/HashLeaf", func(b *testing.B) {
			b.ReportAllocs()
			valueHash := h.hasher.HashValue(value)
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				blake3Sink = h.hasher.HashLeaf(0, 1, int64(i), key, valueHash)
			}
		})
		b.Run(h.name+"/HashInner", func(b *testing.B) {
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				blake3Sink = h.hasher.HashInner(1, 2, int64(i), left, right)
			}
		})
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [16]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}
