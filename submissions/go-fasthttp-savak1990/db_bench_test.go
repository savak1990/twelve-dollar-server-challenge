package main

import (
	"os"
	"path/filepath"
	"testing"
)

// benchDB opens a private copy of the seed database (../../seed/feed.db); skips when absent.
func benchDB(b *testing.B) *db {
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
	d, err := openDB(path)
	if err != nil {
		b.Fatal(err)
	}
	return d
}

func BenchmarkFeed(b *testing.B) {
	d := benchDB(b)
	out := make([]byte, 0, outCap)
	b.ReportAllocs()
	b.ResetTimer()
	for b.Loop() {
		var err error
		if out, _, err = d.query(d.feed, 0, -1, nil, nil, out[:0]); err != nil {
			b.Fatal(err)
		}
	}
	b.SetBytes(int64(len(out)))
}

func BenchmarkPost(b *testing.B) {
	d := benchDB(b)
	out := make([]byte, 0, outCap)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; b.Loop(); i++ {
		var err error
		if out, _, err = d.query(d.post, int64(1+i%500000), -1, nil, nil, out[:0]); err != nil {
			b.Fatal(err)
		}
	}
	b.SetBytes(int64(len(out)))
}

// BenchmarkFeedNoAggOrder is the feed without ORDER BY inside the aggregate. What-if only: that
// ORDER BY is what guarantees the array order whatever plan SQLite picks.
func BenchmarkFeedNoAggOrder(b *testing.B) {
	d := benchDB(b)
	s, err := d.prepare(`SELECT '{"posts":' || json_group_array(json_object('id',id,'body',body,'created_at',ca,'author',username,'like_count',lc)) || '}' FROM (` +
		`SELECT p.id AS id, p.body AS body, p.created_at AS ca, u.username AS username, (SELECT count(*) FROM likes l WHERE l.post_id = p.id) AS lc ` +
		`FROM posts p JOIN users u ON u.id = p.user_id ORDER BY p.created_at DESC, p.id DESC LIMIT 20)`)
	if err != nil {
		b.Fatal(err)
	}
	out := make([]byte, 0, outCap)
	b.ReportAllocs()
	b.ResetTimer()
	for b.Loop() {
		if out, _, err = d.query(s, 0, -1, nil, nil, out[:0]); err != nil {
			b.Fatal(err)
		}
	}
}
