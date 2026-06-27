//go:build ignore

package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/quic-go/quic-go"
)

func main() {
	tlsConf := &tls.Config{
		InsecureSkipVerify: true,
		NextProtos:         []string{"h3"},
	}

	qConfig := &quic.Config{
		HandshakeIdleTimeout: 10 * time.Second,
		MaxIdleTimeout:       30 * time.Second,
		KeepAlivePeriod:      10 * time.Second,
	}

	fmt.Println("Attempting to connect to quic-go server at 127.0.0.1:3143...")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, err := quic.DialAddr(ctx, "127.0.0.1:3143", tlsConf, qConfig)
	if err != nil {
		log.Printf("Failed to connect: %v\n", err)
		os.Exit(1)
	}
	defer conn.CloseWithError(0, "closing")

	fmt.Println("Connection established successfully!")
	fmt.Printf("Remote address: %v\n", conn.RemoteAddr())
	fmt.Printf("Local address: %v\n", conn.LocalAddr())

	// Try to open a stream
	stream, err := conn.OpenStreamSync(context.Background())
	if err != nil {
		log.Printf("Failed to open stream: %v\n", err)
		os.Exit(1)
	}
	defer stream.Close()

	fmt.Println("Stream opened successfully!")
}
