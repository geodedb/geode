package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"os"

	"github.com/quic-go/quic-go"
)

func main() {
	// Test quic-go against vendor reference server
	fmt.Println("Testing quic-go with vendor QUIC server...")

	// Connect to vendor server at localhost:56795 (should be running)
	tlsConf := &tls.Config{
		InsecureSkipVerify: true,
		NextProtos:         []string{"geode/1"},
		MinVersion:         tls.VersionTLS13,
	}

	conn, err := quic.DialAddr(context.Background(), "localhost:56795", tlsConf, nil)
	if err != nil {
		fmt.Fprintf(os.Stderr, "❌ Connection failed: %v\n", err)
		os.Exit(1)
	}
	defer conn.CloseWithError(0, "done")

	fmt.Println("✅ Connection established")

	// Open a stream
	stream, err := conn.OpenStreamSync(context.Background())
	if err != nil {
		fmt.Fprintf(os.Stderr, "❌ Failed to open stream: %v\n", err)
		os.Exit(1)
	}
	defer stream.Close()

	fmt.Println("✅ Stream opened")

	// Send test message
	msg := []byte("Hello from quic-go!")
	_, err = stream.Write(msg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "❌ Write failed: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("✅ Sent: %s\n", msg)

	// Read echo response
	buf := make([]byte, 1024)
	n, err := stream.Read(buf)
	if err != nil && err != io.EOF {
		fmt.Fprintf(os.Stderr, "❌ Read failed: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("✅ Received: %s\n", buf[:n])
	fmt.Println("\n✅ TEST PASSED - quic-go works with vendor server!")
}
