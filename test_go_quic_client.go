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
	fmt.Println("Testing QUIC connection to localhost:7567...")

	// Create TLS config that accepts self-signed certificates
	tlsConf := &tls.Config{
		InsecureSkipVerify: true,
		NextProtos:         []string{"hq-interop", "h3"},
	}

	// Create QUIC config with some lenient settings
	quicConf := &quic.Config{
		HandshakeIdleTimeout: 10 * time.Second,
		MaxIdleTimeout:       30 * time.Second,
		KeepAlivePeriod:      10 * time.Second,
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Try to establish QUIC connection
	conn, err := quic.DialAddr(ctx, "localhost:7567", tlsConf, quicConf)
	if err != nil {
		log.Fatalf("Failed to connect: %v", err)
	}
	defer conn.CloseWithError(0, "done")

	fmt.Println("Connected successfully!")

	// Try to open a stream
	stream, err := conn.OpenStreamSync(context.Background())
	if err != nil {
		log.Fatalf("Failed to open stream: %v", err)
	}
	defer stream.Close()

	// Send some data
	data := []byte("RETURN 1 AS test")
	_, err = stream.Write(data)
	if err != nil {
		log.Fatalf("Failed to write: %v", err)
	}

	fmt.Println("Data sent, waiting for response...")

	// Try to read response
	buf := make([]byte, 1024)
	n, err := stream.Read(buf)
	if err != nil {
		log.Printf("Read error: %v", err)
	} else {
		fmt.Printf("Received %d bytes: %s\n", n, buf[:n])
	}

	fmt.Println("Test completed")
}