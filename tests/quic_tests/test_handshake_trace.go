//go:build ignore

package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"os"
	"time"

	"github.com/quic-go/quic-go"
)

func main() {
	addr := "127.0.0.1:13200"

	// Enable SSLKEYLOG for wireshark decryption
	keylogFile, err := os.Create("/tmp/quic_keylog.txt")
	if err != nil {
		fmt.Printf("Failed to create keylog file: %v\n", err)
	}
	defer keylogFile.Close()

	tlsConf := &tls.Config{
		InsecureSkipVerify: true,
		NextProtos:         []string{"geode/1"},
		KeyLogWriter:       keylogFile,
	}

	quicConf := &quic.Config{
		HandshakeIdleTimeout: 5 * time.Second,
	}

	fmt.Printf("Connecting to %s with 5s handshake timeout...\n", addr)
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()

	conn, err := quic.DialAddr(ctx, addr, tlsConf, quicConf)
	if err != nil {
		fmt.Printf("FAIL: %v\n", err)
		fmt.Printf("Error type: %T\n", err)
		os.Exit(1)
	}
	defer conn.CloseWithError(0, "done")
	fmt.Printf("SUCCESS: Connected! Remote=%v\n", conn.RemoteAddr())
}
