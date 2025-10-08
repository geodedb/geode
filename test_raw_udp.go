package main

import (
	"fmt"
	"log"
	"net"
	"time"
)

func main() {
	// Create UDP address
	serverAddr, err := net.ResolveUDPAddr("udp", "127.0.0.1:3141")
	if err != nil {
		log.Fatalf("Failed to resolve: %v", err)
	}

	// Create UDP connection
	conn, err := net.DialUDP("udp", nil, serverAddr)
	if err != nil {
		log.Fatalf("Failed to dial: %v", err)
	}
	defer conn.Close()

	fmt.Printf("Connected to %s\n", serverAddr)
	fmt.Printf("Local address: %s\n", conn.LocalAddr())

	// Send test data
	msg := []byte("Hello from raw UDP!")
	n, err := conn.Write(msg)
	if err != nil {
		log.Fatalf("Failed to write: %v", err)
	}

	fmt.Printf("Sent %d bytes\n", n)
	time.Sleep(1 * time.Second)
}
