package main

import (
	"os"
	"path/filepath"
	"testing"
)

// benchDB opens a private copy of the seed database (../../seed/feed.db) with the given backend;
// skips when the seed is absent.
func benchDB(b *testing.B, backend string) *db {
	b.Helper()
	src := filepath.Join("..", "..", "seed", "feed.db")
	data, err := os.ReadFile(src)
	if err != nil {
		b.Skipf("no seed database at %s (make seed)", src)
	}
	path := filepath.Join(b.TempDir(), "feed.db")
	if err := os.WriteFile(path, data, 0o644); err != nil {
		b.Fatal(err)
	}
	d, err := openDB(path, backend)
	if err != nil {
		b.Fatal(err)
	}
	return d
}

// Per-query cost of the two read statements through each engine, on the calling goroutine
// (the DB goroutine is idle, so this is the engine alone).
func BenchmarkFeed(b *testing.B) {
	for _, backend := range []string{"cgo", "go"} {
		b.Run(backend, func(b *testing.B) {
			d := benchDB(b, backend)
			out := make([]byte, 0, outCap)
			b.ReportAllocs()
			b.ResetTimer()
			for b.Loop() {
				var err error
				if out, _, err = d.eng.run(qFeed, 0, -1, nil, nil, out[:0]); err != nil {
					b.Fatal(err)
				}
			}
			b.SetBytes(int64(len(out)))
		})
	}
}

func BenchmarkPost(b *testing.B) {
	for _, backend := range []string{"cgo", "go"} {
		b.Run(backend, func(b *testing.B) {
			d := benchDB(b, backend)
			out := make([]byte, 0, outCap)
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; b.Loop(); i++ {
				var err error
				if out, _, err = d.eng.run(qPost, int64(1+i%500000), -1, nil, nil, out[:0]); err != nil {
					b.Fatal(err)
				}
			}
			b.SetBytes(int64(len(out)))
		})
	}
}
