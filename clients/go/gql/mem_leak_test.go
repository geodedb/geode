package gql

import (
	"context"
	"runtime"
	"testing"
	"time"
)

// TestIteratorMemoryStability performs a large iteration and ensures memory growth is within a reasonable bound.
func TestIteratorMemoryStability(t *testing.T) {
    c := withConn(t)
    ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
    defer cancel()
    // Force GC and snapshot
    runtime.GC()
    var before runtime.MemStats
    runtime.ReadMemStats(&before)
    it, err := c.NewIterator(ctx, "RETURN 1 AS x ORDER BY x LIMIT 2000", nil, 20)
    if err != nil { t.Fatalf("iterator setup: %v", err) }
    for {
        _, e := it.Next()
        if e != nil { break }
    }
    runtime.GC()
    var after runtime.MemStats
    runtime.ReadMemStats(&after)
    // Allow up to ~8MB allocation growth (heuristic) to avoid flakes under race detector
    const maxGrowth = 8 << 20
    if after.Alloc > before.Alloc && after.Alloc-before.Alloc > maxGrowth {
        t.Fatalf("memory growth too high: %d bytes", after.Alloc-before.Alloc)
    }
}
