package main

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"log"
	"math/big"
	"os"
	"time"

	"github.com/quic-go/quic-go"
	"github.com/quic-go/quic-go/logging"
	"github.com/quic-go/quic-go/qlog"
)

func generateTLSConfig() *tls.Config {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		panic(err)
	}
	template := x509.Certificate{
		SerialNumber: big.NewInt(1),
		DNSNames:     []string{"localhost"},
	}
	certDER, err := x509.CreateCertificate(rand.Reader, &template, &template, &key.PublicKey, key)
	if err != nil {
		panic(err)
	}
	keyPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "RSA PRIVATE KEY",
		Bytes: x509.MarshalPKCS1PrivateKey(key),
	})
	certPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "CERTIFICATE",
		Bytes: certDER,
	})

	tlsCert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		panic(err)
	}
	return &tls.Config{
		Certificates: []tls.Certificate{tlsCert},
		NextProtos:   []string{"h3"},
	}
}

func main() {
	// Enable detailed logging
	qlogger := qlog.DefaultTracer(func(p logging.Perspective, connID []byte) qlog.WriteCloser {
		filename := fmt.Sprintf("server_%x.qlog", connID)
		f, err := os.Create(filename)
		if err != nil {
			log.Fatal(err)
		}
		return qlog.NewWriter(f)
	})

	tlsConf := generateTLSConfig()

	qConfig := &quic.Config{
		Tracer:               qlogger,
		HandshakeIdleTimeout: 10 * time.Second,
		MaxIdleTimeout:       30 * time.Second,
		KeepAlivePeriod:      10 * time.Second,
	}

	fmt.Println("Starting QUIC server on 127.0.0.1:3142...")
	listener, err := quic.ListenAddr("127.0.0.1:3142", tlsConf, qConfig)
	if err != nil {
		log.Fatal(err)
	}

	fmt.Println("Waiting for connections...")
	for {
		conn, err := listener.Accept(context.Background())
		if err != nil {
			log.Printf("Failed to accept connection: %v", err)
			continue
		}

		fmt.Printf("Connection from %v\n", conn.RemoteAddr())
		go handleConnection(conn)
	}
}

func handleConnection(conn quic.Connection) {
	fmt.Printf("Handling connection from %v\n", conn.RemoteAddr())
	// Just accept streams for now
	for {
		stream, err := conn.AcceptStream(context.Background())
		if err != nil {
			log.Printf("Failed to accept stream: %v", err)
			return
		}
		fmt.Printf("Stream accepted: %v\n", stream.StreamID())
		stream.Close()
	}
}