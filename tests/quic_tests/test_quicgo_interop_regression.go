//go:build ignore

// GAP-60 Regression Test: quic-go interop
//
// Verifies that quic-go (v0.54+) can complete TLS handshake and open
// bidirectional streams against the Geode QUIC server.
//
// This test was added after GAP #60 documented a regression where
// quic-go v0.55-v0.59 could not handshake with Geode v0.1.12+.
// The root cause was connection handling bottlenecks in the accept
// loop (fixed in commit a11c2104).
//
// Usage:
//
//	Start Geode server first:
//	  GEODE_ADMIN_PASSWORD=test ./zig-out/bin/geode serve --listen 127.0.0.1:3141
//	Then run:
//	  go run tests/quic_tests/test_quicgo_interop_regression.go [-addr 127.0.0.1:3141] [-n 10]
package main

import (
	"context"
	"crypto/tls"
	"flag"
	"fmt"
	"log"
	"sync"
	"sync/atomic"
	"time"

	"github.com/quic-go/quic-go"
)

func main() {
	var addr string
	var numConns int
	var timeout int
	flag.StringVar(&addr, "addr", "127.0.0.1:3141", "Geode server address")
	flag.IntVar(&numConns, "n", 10, "Number of concurrent connections")
	flag.IntVar(&timeout, "timeout", 6, "Connection timeout in seconds")
	flag.Parse()

	tlsConf := &tls.Config{
		InsecureSkipVerify: true,
		NextProtos:         []string{"geode/1"},
		MinVersion:         tls.VersionTLS13,
	}

	qConfig := &quic.Config{
		MaxIdleTimeout:       30 * time.Second,
		HandshakeIdleTimeout: time.Duration(timeout) * time.Second,
		Versions:             []quic.Version{quic.Version1},
	}

	fmt.Printf("GAP-60 Regression: testing %d concurrent quic-go connections to %s\n", numConns, addr)

	// Phase 1: Single connection handshake + stream
	fmt.Println("\n--- Phase 1: Single connection ---")
	{
		ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeout)*time.Second)
		defer cancel()

		start := time.Now()
		conn, err := quic.DialAddr(ctx, addr, tlsConf, qConfig)
		if err != nil {
			log.Fatalf("FAIL: single handshake failed after %v: %v", time.Since(start), err)
		}

		stream, err := conn.OpenStreamSync(ctx)
		if err != nil {
			conn.CloseWithError(1, "stream failed")
			log.Fatalf("FAIL: single stream open failed: %v", err)
		}
		stream.Close()
		conn.CloseWithError(0, "done")
		fmt.Printf("PASS: handshake + stream in %v\n", time.Since(start))
	}

	// Phase 2: Concurrent connections
	fmt.Printf("\n--- Phase 2: %d concurrent connections ---\n", numConns)
	var passed atomic.Int32
	var failed atomic.Int32
	var wg sync.WaitGroup

	start := time.Now()
	for i := 0; i < numConns; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeout)*time.Second)
			defer cancel()

			conn, err := quic.DialAddr(ctx, addr, tlsConf, qConfig)
			if err != nil {
				log.Printf("[%d] FAIL handshake: %v", id, err)
				failed.Add(1)
				return
			}
			defer conn.CloseWithError(0, "done")

			stream, err := conn.OpenStreamSync(ctx)
			if err != nil {
				log.Printf("[%d] FAIL stream: %v", id, err)
				failed.Add(1)
				return
			}
			stream.Close()
			passed.Add(1)
		}(i)
		// Small stagger to avoid UDP buffer saturation
		time.Sleep(10 * time.Millisecond)
	}
	wg.Wait()
	elapsed := time.Since(start)

	p := passed.Load()
	f := failed.Load()
	fmt.Printf("Results: %d/%d passed in %v\n", p, numConns, elapsed)

	if f > 0 {
		fmt.Printf("\nFAIL: %d connections failed (GAP-60 regression)\n", f)
		log.Fatal("GAP-60 regression detected")
	}

	// Phase 3: Sequential rapid reconnections (tests accept loop recovery)
	fmt.Println("\n--- Phase 3: Sequential rapid reconnect ---")
	for i := 0; i < 5; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeout)*time.Second)
		conn, err := quic.DialAddr(ctx, addr, tlsConf, qConfig)
		if err != nil {
			cancel()
			log.Fatalf("FAIL: reconnect %d failed: %v", i, err)
		}
		conn.CloseWithError(0, "reconnect test")
		cancel()
	}
	fmt.Println("PASS: 5 rapid reconnections")

	fmt.Println("\n=== ALL GAP-60 REGRESSION TESTS PASSED ===")
}
