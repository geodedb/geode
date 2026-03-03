// Minimal handshake debug test
package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"log"
	"net"
	"time"

	"github.com/quic-go/quic-go"
)

func main() {
	addr := "127.0.0.1:13199"

	// First: verify UDP reachability
	fmt.Println("Step 1: Testing UDP reachability...")
	udpAddr, _ := net.ResolveUDPAddr("udp", addr)
	udpConn, err := net.DialUDP("udp", nil, udpAddr)
	if err != nil {
		log.Fatalf("UDP dial failed: %v", err)
	}
	_, err = udpConn.Write([]byte("test"))
	if err != nil {
		log.Fatalf("UDP write failed: %v", err)
	}
	udpConn.Close()
	fmt.Println("  UDP reachable")

	// Second: try QUIC handshake with verbose TLS
	fmt.Println("Step 2: QUIC handshake...")
	tlsConf := &tls.Config{
		InsecureSkipVerify: true,
		NextProtos:         []string{"geode/1"},
		MinVersion:         tls.VersionTLS13,
	}

	qConfig := &quic.Config{
		MaxIdleTimeout:       30 * time.Second,
		HandshakeIdleTimeout: 10 * time.Second,
		Versions:             []quic.Version{quic.Version1},
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	start := time.Now()
	fmt.Printf("  Dialing %s with ALPN=%v, QUIC versions=%v\n", addr, tlsConf.NextProtos, qConfig.Versions)

	conn, err := quic.DialAddr(ctx, addr, tlsConf, qConfig)
	if err != nil {
		fmt.Printf("  FAIL after %v: %v\n", time.Since(start), err)

		// Try without ALPN
		fmt.Println("\nStep 3: Retry without ALPN...")
		tlsConf2 := &tls.Config{
			InsecureSkipVerify: true,
			MinVersion:         tls.VersionTLS13,
		}
		ctx2, cancel2 := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel2()
		start2 := time.Now()
		conn2, err2 := quic.DialAddr(ctx2, addr, tlsConf2, qConfig)
		if err2 != nil {
			fmt.Printf("  FAIL without ALPN after %v: %v\n", time.Since(start2), err2)
		} else {
			fmt.Printf("  PASS without ALPN in %v\n", time.Since(start2))
			conn2.CloseWithError(0, "done")
		}
		return
	}
	fmt.Printf("  PASS in %v\n", time.Since(start))
	fmt.Printf("  TLS version: 0x%04x\n", conn.ConnectionState().TLS.Version)
	fmt.Printf("  ALPN: %s\n", conn.ConnectionState().TLS.NegotiatedProtocol)
	conn.CloseWithError(0, "done")
}
