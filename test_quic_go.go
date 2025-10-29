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
	log.Println("Starting QUIC connection test to localhost:7567")

	// Configure TLS with skip verification for testing
	tlsConfig := &tls.Config{
		InsecureSkipVerify: true,
		NextProtos:         []string{"geode/1"},
		MinVersion:         tls.VersionTLS13,
	}

	// QUIC config
	quicConfig := &quic.Config{
		MaxIdleTimeout:        30 * time.Second,
		HandshakeIdleTimeout:  10 * time.Second,
		KeepAlivePeriod:       10 * time.Second,
		EnableDatagrams:       false,
		Allow0RTT:             false,
	}

	log.Println("Dialing QUIC server...")

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	conn, err := quic.DialAddr(ctx, "localhost:7567", tlsConfig, quicConfig)
	if err != nil {
		log.Fatalf("Failed to dial: %v", err)
	}
	defer conn.CloseWithError(0, "closing")

	log.Println("✓ Successfully connected!")
	log.Printf("Connection info: Local=%v Remote=%v", conn.LocalAddr(), conn.RemoteAddr())
	log.Printf("Connection state: %+v", conn.ConnectionState())

	// Try to open a stream
	stream, err := conn.OpenStreamSync(context.Background())
	if err != nil {
		log.Fatalf("Failed to open stream: %v", err)
	}
	defer stream.Close()

	log.Println("✓ Successfully opened stream!")

	// Send a simple query
	query := "RETURN 1 AS test"
	log.Printf("Sending query: %s", query)

	_, err = stream.Write([]byte(query))
	if err != nil {
		log.Fatalf("Failed to write to stream: %v", err)
	}

	log.Println("✓ Query sent successfully!")

	// Try to read response
	buf := make([]byte, 1024)
	n, err := stream.Read(buf)
	if err != nil {
		log.Printf("Warning: Failed to read response: %v", err)
	} else {
		log.Printf("Received %d bytes: %s", n, string(buf[:n]))
	}

	fmt.Println("\n[GO-CLIENT] Test completed successfully - QUIC connection works!")
}