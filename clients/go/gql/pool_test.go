package gql

import (
	"context"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

// TestPoolConcurrency ensures that with many goroutines and limited max, connections are reused.
func TestPoolConcurrency(t *testing.T) { // part of pool tests
	if testing.Short() || os.Getenv("CI") != "" {
		t.Skip("Skipping pool concurrency test in CI/short mode")
	}
	startTCP(t)
	p := NewPool("127.0.0.1:7567", "gql-go", "0.1", "min", 32, 3, 10*time.Second) // supply TCP addr
	ctx := context.Background()
	var wg sync.WaitGroup
	iters := 30
	conns := make(chan *Conn, iters)
	for i := 0; i < iters; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			c, err := p.Acquire(ctx)
			if err != nil { t.Errorf("acquire: %v", err); return }
			// simple query
			_, _, _ = c.Query(ctx, "RETURN 1 AS x", nil, 4)
			p.Release(c)
			conns <- c
		}()
	}
	wg.Wait()
	close(conns)
	// Count unique pointer addresses used
	uniq := map[*Conn]struct{}{}
	for c := range conns { uniq[c] = struct{}{} }
	if len(uniq) > 3 { t.Fatalf("expected at most 3 connections, got %d", len(uniq)) }
	p.Close()
}

// TestPoolAcquireTimeout ensures Acquire times out when closed.
func TestPoolAcquireTimeout(t *testing.T) {
	if testing.Short() || os.Getenv("CI") != "" {
		t.Skip("Skipping pool acquire timeout test in CI/short mode")
	}
	startTCP(t)
	time.Sleep(50 * time.Millisecond) // Give server time to stabilize
	p := NewPool("127.0.0.1:7567", "gql-go", "0.1", "min", 32, 1, 10*time.Second)
	ctx := context.Background()
	c, err := p.Acquire(ctx)
	if err != nil { t.Fatalf("first acquire: %v", err) }
	// Close pool to force error on next acquire
	p.Close()
	c2, err := p.Acquire(ctx)
	if err == nil || c2 != nil { t.Fatalf("expected error acquiring from closed pool") }
	_ = c
}

// TestPoolIdleTimeout ensures idle connections are pruned after timeout.
func TestPoolIdleTimeout(t *testing.T) {
	if testing.Short() || os.Getenv("CI") != "" {
		t.Skip("Skipping pool idle timeout test in CI/short mode")
	}
	startTCP(t)
	p := NewPool("127.0.0.1:7567", "gql-go", "0.1", "min", 32, 2, 50*time.Millisecond)
	ctx := context.Background()
	c1, err := p.Acquire(ctx); if err != nil { t.Fatalf("acq1: %v", err) }
	p.Release(c1)
	time.Sleep(120 * time.Millisecond) // exceed idle timeout
	c2, err := p.Acquire(ctx); if err != nil {
		if strings.Contains(err.Error(), "connection refused") {
			// Retry: server may have died; restart and retry once
			startTCP(t)
			c2, err = p.Acquire(ctx)
		}
		if err != nil { t.Fatalf("acq2: %v", err) }
	}
	if c1 == c2 { t.Fatalf("expected new connection after idle timeout prune") }
	p.Release(c2)
	p.Close()
}
