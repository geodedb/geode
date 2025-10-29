package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"log"
	"time"

	"github.com/quic-go/quic-go"
	"github.com/quic-go/quic-go/logging"
)

func main() {
	log.SetPrefix("[GO-CLIENT] ")
	log.Println("Starting QUIC connection test with debug logging")

	// Configure TLS with skip verification for testing
	tlsConfig := &tls.Config{
		InsecureSkipVerify: true,
		NextProtos:         []string{"geode/1"},
		MinVersion:         tls.VersionTLS13,
		KeyLogWriter:       &keyLogger{},
	}

	// QUIC config with qlog tracing
	quicConfig := &quic.Config{
		MaxIdleTimeout:       30 * time.Second,
		HandshakeIdleTimeout: 10 * time.Second,
		KeepAlivePeriod:      10 * time.Second,
		EnableDatagrams:      false,
		Allow0RTT:            false,
		Tracer: func(ctx context.Context, p logging.Perspective, connID quic.ConnectionID) *logging.ConnectionTracer {
			return &logging.ConnectionTracer{
				SentPacket: func(hdr *logging.ExtendedHeader, size logging.ByteCount, ack *logging.AckFrame, frames []logging.Frame) {
					log.Printf("Sent %s packet (PN %d): %d bytes", hdr.Type, hdr.PacketNumber, size)
					for _, f := range frames {
						if cf, ok := f.(*logging.CryptoFrame); ok {
							log.Printf("  CRYPTO frame: offset=%d len=%d", cf.Offset, cf.Length)
						}
					}
				},
				ReceivedPacket: func(hdr *logging.ExtendedHeader, size logging.ByteCount, frames []logging.Frame) {
					log.Printf("Received %s packet (PN %d): %d bytes", hdr.Type, hdr.PacketNumber, size)
					for _, f := range frames {
						if cf, ok := f.(*logging.CryptoFrame); ok {
							log.Printf("  CRYPTO frame: offset=%d len=%d", cf.Offset, cf.Length)
						}
					}
				},
				DroppedPacket: func(hdr *logging.ExtendedHeader, size logging.ByteCount, reason logging.PacketDropReason) {
					log.Printf("Dropped %s packet (PN %d): reason=%v", hdr.Type, hdr.PacketNumber, reason)
				},
			}
		},
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

	fmt.Println("\n[GO-CLIENT] Test completed successfully - QUIC connection works!")
}

// keyLogger logs TLS key material
type keyLogger struct{}

func (k *keyLogger) Write(p []byte) (n int, err error) {
	log.Printf("TLS Key Log: %s", string(p))
	return len(p), nil
}