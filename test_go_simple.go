package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"log"
	"time"

	"github.com/quic-go/quic-go"
)

func main() {
	log.SetPrefix("[GO-CLIENT] ")
	log.Println("Starting simple QUIC connection test")

	// Configure TLS with skip verification for testing
	tlsConfig := &tls.Config{
		InsecureSkipVerify: true,
		NextProtos:         []string{"geode/1"},
		MinVersion:         tls.VersionTLS13,
	}

	// QUIC config
	quicConfig := &quic.Config{
		MaxIdleTimeout:       30 * time.Second,
		HandshakeIdleTimeout: 10 * time.Second,
		KeepAlivePeriod:      10 * time.Second,
		EnableDatagrams:      false,
		Allow0RTT:            false,
	}

	log.Println("Dialing QUIC server at localhost:7567...")

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	conn, err := quic.DialAddr(ctx, "localhost:7567", tlsConfig, quicConfig)
	if err != nil {
		log.Fatalf("❌ Failed to dial: %v", err)
	}
	defer conn.CloseWithError(0, "closing")

	log.Println("✓ Successfully connected!")
	log.Printf("Connection info: Local=%v Remote=%v", conn.LocalAddr(), conn.RemoteAddr())

	// Check connection state
	state := conn.ConnectionState()
	log.Printf("Connection state: TLS=%v SupportsDatagrams=%v Used0RTT=%v",
		state.TLS.HandshakeComplete, state.SupportsDatagrams, state.Used0RTT)

	// Try to open a stream
	stream, err := conn.OpenStreamSync(context.Background())
	if err != nil {
		log.Printf("Failed to open stream: %v", err)
	} else {
		log.Println("✓ Successfully opened stream!")
		stream.Close()
	}

	fmt.Println("\n[GO-CLIENT] Test completed successfully - QUIC connection and handshake complete!")
}