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
	"github.com/quic-go/quic-go/qlogwriter"
)

func main() {
	tlsConf := &tls.Config{
		InsecureSkipVerify: true,
		NextProtos:         []string{"h3"},
	}

	qConfig := &quic.Config{
		// quic-go v0.60: Tracer uses qlogwriter.Trace; logging/qlog subpkg removed.
		Tracer: func(_ context.Context, isClient bool, connID quic.ConnectionID) qlogwriter.Trace {
			filename := fmt.Sprintf("client_%x.qlog", connID)
			f, err := os.Create(filename)
			if err != nil {
				log.Fatal(err)
			}
			t := qlogwriter.NewConnectionFileSeq(f, isClient, connID, nil)
			go t.Run()
			return t
		},
		HandshakeIdleTimeout: 10 * time.Second,
		MaxIdleTimeout:       30 * time.Second,
		KeepAlivePeriod:      10 * time.Second,
	}

	fmt.Println("Attempting to connect to 127.0.0.1:3143...")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, err := quic.DialAddr(ctx, "127.0.0.1:3143", tlsConf, qConfig)
	if err != nil {
		fmt.Printf("Failed to connect: %v\n", err)
		os.Exit(1)
	}
	defer conn.CloseWithError(0, "done") // quic-go v0.60: Close() removed, use CloseWithError

	fmt.Println("Connection established successfully!")
	fmt.Printf("Remote address: %v\n", conn.RemoteAddr())
	fmt.Printf("Local address: %v\n", conn.LocalAddr())

	// Try to open a stream
	stream, err := conn.OpenStreamSync(context.Background())
	if err != nil {
		fmt.Printf("Failed to open stream: %v\n", err)
		os.Exit(1)
	}
	defer stream.Close()

	fmt.Println("Stream opened successfully!")
}
