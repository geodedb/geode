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
	addr := os.Args[1]

	tlsConf := &tls.Config{
		InsecureSkipVerify: true,
		NextProtos:         []string{"geode/1"},
	}

	quicConf := &quic.Config{
		HandshakeIdleTimeout: 5 * time.Second,
	}

	fmt.Printf("Connecting to %s...\n", addr)
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()

	conn, err := quic.DialAddr(ctx, addr, tlsConf, quicConf)
	if err != nil {
		fmt.Printf("FAIL: %v\n", err)
		os.Exit(1)
	}
	defer conn.CloseWithError(0, "done")
	fmt.Printf("SUCCESS: Connected to %s\n", conn.RemoteAddr())
}
