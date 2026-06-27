//go:build ignore

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
	// Configure TLS
	tlsConf := &tls.Config{
		InsecureSkipVerify: true, // Skip verification for testing
		NextProtos:         []string{"geode/1"},
		MinVersion:         tls.VersionTLS13,
	}

	// Configure QUIC
	qConfig := &quic.Config{
		MaxIdleTimeout:        30 * time.Second,
		KeepAlivePeriod:       10 * time.Second,
		HandshakeIdleTimeout:  10 * time.Second,
		MaxIncomingStreams:    100,
		MaxIncomingUniStreams: 100,
		Versions:              []quic.Version{quic.Version1}, // Force QUIC v1
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	fmt.Println("Attempting to connect to 127.0.0.1:3141...")

	// Connect
	conn, err := quic.DialAddr(ctx, "127.0.0.1:3141", tlsConf, qConfig)
	if err != nil {
		log.Fatalf("Failed to connect: %v", err)
	}
	defer conn.CloseWithError(0, "test complete")

	fmt.Println("QUIC connection established!")

	// Try to open a stream
	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		log.Fatalf("Failed to open stream: %v", err)
	}
	defer stream.Close()

	fmt.Println("Stream opened successfully!")

	// Send test data
	msg := []byte("Hello QUIC server!")
	if _, err := stream.Write(msg); err != nil {
		log.Fatalf("Failed to write: %v", err)
	}

	fmt.Println("Test completed successfully!")
}
